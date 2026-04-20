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

enum AssistantRuntimeControlsAvailability: String, Codable, Sendable {
    case ready
    case busy
    case loadingModels
    case switchingProvider
    case unavailable

    var isReady: Bool {
        self == .ready
    }

    var fallbackStatusText: String {
        switch self {
        case .ready:
            return ""
        case .busy:
            return "Responding..."
        case .loadingModels:
            return "Loading models..."
        case .switchingProvider:
            return "Starting provider..."
        case .unavailable:
            return "Runtime unavailable"
        }
    }
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
        formattedResetLabel(hourOnly: false)
    }

    var compactResetsInLabel: String? {
        formattedResetLabel(hourOnly: true)
    }

    private func formattedResetLabel(hourOnly: Bool) -> String? {
        guard let resetsAt else { return nil }
        guard resetsAt.timeIntervalSinceNow > 0 else { return "now" }
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = false
        let calendar = Calendar.current
        if calendar.isDateInToday(resetsAt) {
            formatter.dateFormat = hourOnly ? "h a" : "'today at' h:mm a"
        } else if calendar.isDateInTomorrow(resetsAt) {
            formatter.dateFormat = hourOnly ? "'tomorrow' h a" : "'tomorrow at' h:mm a"
        } else {
            formatter.dateFormat = hourOnly ? "EEE h a" : "EEE h:mm a"
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

private func assistantDisplayModelName(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return value }
    if trimmed.contains(where: \.isWhitespace) {
        return trimmed
    }

    var splitIndex = trimmed.startIndex
    while splitIndex < trimmed.endIndex, trimmed[splitIndex].isLetter {
        splitIndex = trimmed.index(after: splitIndex)
    }

    guard splitIndex > trimmed.startIndex else {
        return trimmed
    }

    let prefix = String(trimmed[..<splitIndex]).uppercased()
    let suffix = String(trimmed[splitIndex...])
    return prefix + suffix
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

        let defaultBucket = buckets.first(where: \.isDefaultCodex)
        let nonDefaultBuckets = buckets.filter { !$0.isDefaultCodex }
        guard let normalizedModelID = normalizedRateLimitSearchText(modelID) else {
            return defaultBucket ?? buckets.first
        }

        if normalizedModelID.contains("spark") {
            if let sparkBucket = nonDefaultBuckets.first(where: { $0.searchText.contains("spark") }) {
                return sparkBucket
            }

            if let explicitMatch = nonDefaultBuckets.first(where: { bucket in
                let searchText = bucket.searchText
                return !searchText.isEmpty
                    && (searchText == normalizedModelID
                        || searchText.hasPrefix(normalizedModelID + " ")
                        || normalizedModelID.hasPrefix(searchText + " "))
            }) {
                return explicitMatch
            }

            if nonDefaultBuckets.count == 1, defaultBucket == nil {
                return nonDefaultBuckets[0]
            }
        }

        if let matchingBucket = nonDefaultBuckets.first(where: { bucket in
            let searchText = bucket.searchText
            return !searchText.isEmpty
                && (searchText == normalizedModelID
                    || searchText.hasPrefix(normalizedModelID + " ")
                    || normalizedModelID.hasPrefix(searchText + " "))
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

struct StatusBarRateLimitEntry: Equatable, Sendable {
    var window: RateLimitWindow
    var showsResetInline: Bool
}

extension AccountRateLimitBucket {
    func statusBarEntries(bucketLabel: String?) -> [StatusBarRateLimitEntry] {
        let hasBucketLabel = bucketLabel?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty != nil
        var entries: [StatusBarRateLimitEntry] = []

        if let primary {
            entries.append(
                StatusBarRateLimitEntry(
                    window: primary,
                    showsResetInline: hasBucketLabel
                )
            )
        }

        if let secondary {
            entries.append(
                StatusBarRateLimitEntry(
                    window: secondary,
                    showsResetInline: hasBucketLabel
                )
            )
        }

        return entries
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

struct AssistantProviderRuntimeSurfaceSnapshot: Equatable, Sendable {
    var accountSnapshot: AssistantAccountSnapshot = .signedOut
    var availableModels: [AssistantModelOption] = []
    var tokenUsage: TokenUsageSnapshot = .empty
    var rateLimits: AccountRateLimits = .empty
    var selectedModelID: String? = nil

    static let empty = AssistantProviderRuntimeSurfaceSnapshot()
}

struct SubagentState: Identifiable, Equatable, Sendable {
    let id: String
    var parentThreadID: String?
    var threadID: String?
    var nickname: String?
    var role: String?
    var status: SubagentStatus
    var prompt: String?
    var startedAt: Date?
    var updatedAt: Date?
    var endedAt: Date?
    var planEntries: [AssistantPlanEntry] = []

    var displayName: String {
        if let nickname, !nickname.isEmpty { return nickname }
        if let role, !role.isEmpty { return role }
        return "Agent \(id.prefix(6))"
    }

    var roleLabel: String? {
        role?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty?
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    var promptPreview: String? {
        prompt?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
    }

    var lastEventAt: Date? {
        endedAt ?? updatedAt ?? startedAt
    }

    var statusText: String {
        switch status {
        case .spawning:
            return "Starting"
        case .running:
            return "Working"
        case .waiting:
            return "Awaiting instruction"
        case .completed:
            return "Completed"
        case .errored:
            return "Needs attention"
        case .closed:
            return "Closed"
        }
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
struct AssistantAttachment: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    let filename: String
    let data: Data
    let mimeType: String
    private let cachedPreviewDataURL: String?

    init(id: UUID = UUID(), filename: String, data: Data, mimeType: String) {
        self.id = id
        self.filename = filename
        self.data = data
        self.mimeType = mimeType
        self.cachedPreviewDataURL = Self.makePreviewDataURL(data: data, mimeType: mimeType)
    }

    var isImage: Bool { mimeType.hasPrefix("image/") }
    var previewDataURL: String? { cachedPreviewDataURL }
    var dataURL: String { cachedPreviewDataURL ?? "data:\(mimeType);base64,\(data.base64EncodedString())" }

    /// Build the Codex input item for this attachment.
    func toInputItem() -> [String: Any] {
        if isImage {
            return [
                "type": "image",
                "url": dataURL
            ]
        } else {
            return [
                "type": "text",
                "text": "[Attached file: \(filename) (\(mimeType))]"
            ]
        }
    }

    static func == (lhs: AssistantAttachment, rhs: AssistantAttachment) -> Bool {
        lhs.id == rhs.id
    }

    enum CodingKeys: String, CodingKey {
        case id
        case filename
        case data
        case mimeType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let filename = try container.decode(String.self, forKey: .filename)
        let data = try container.decode(Data.self, forKey: .data)
        let mimeType = try container.decode(String.self, forKey: .mimeType)
        self.init(id: id, filename: filename, data: data, mimeType: mimeType)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(filename, forKey: .filename)
        try container.encode(data, forKey: .data)
        try container.encode(mimeType, forKey: .mimeType)
    }

    private static func makePreviewDataURL(data: Data, mimeType: String) -> String? {
        mimeType.hasPrefix("image/")
            ? "data:\(mimeType);base64,\(data.base64EncodedString())"
            : nil
    }
}

struct AssistantTranscriptEntry: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    let role: AssistantTranscriptRole
    let text: String
    let createdAt: Date
    let emphasis: Bool
    let isStreaming: Bool
    let providerBackend: AssistantRuntimeBackend?
    let providerModelID: String?
    let selectedPlugins: [AssistantComposerPluginSelection]?

    init(
        id: UUID = UUID(),
        role: AssistantTranscriptRole,
        text: String,
        createdAt: Date = Date(),
        emphasis: Bool = false,
        isStreaming: Bool = false,
        providerBackend: AssistantRuntimeBackend? = nil,
        providerModelID: String? = nil,
        selectedPlugins: [AssistantComposerPluginSelection]? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.emphasis = emphasis
        self.isStreaming = isStreaming
        self.providerBackend = providerBackend
        self.providerModelID = providerModelID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        self.selectedPlugins = selectedPlugins?.isEmpty == false ? selectedPlugins : nil
    }
}

struct SelectionSideAssistantChatSummarySnapshot: Equatable, Sendable {
    let fingerprint: String
    let summary: String
}

enum SelectionSideAssistantChatSummaryBuilder {
    static func build(
        sessionID: String,
        sessionTitle: String?,
        sessionSummary: String?,
        transcriptEntries: [AssistantTranscriptEntry],
        maxEntries: Int = 6,
        maxCharsPerEntry: Int = 80,
        maxTotalChars: Int = 520
    ) -> SelectionSideAssistantChatSummarySnapshot? {
        let meaningfulEntries = transcriptEntries
            .filter { entry in
                guard !entry.isStreaming else { return false }
                return roleLabel(for: entry.role) != nil
                    && entry.text.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty != nil
            }
            .suffix(maxEntries)

        let normalizedTitle = sessionTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
        let normalizedSessionSummary = sessionSummary?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty

        guard normalizedTitle != nil || normalizedSessionSummary != nil || !meaningfulEntries.isEmpty else {
            return nil
        }

        var lines: [String] = ["# Recent Chat Context"]
        var fingerprintParts: [String] = [sessionID.lowercased()]

        if !meaningfulEntries.isEmpty {
            for entry in meaningfulEntries {
                guard let label = roleLabel(for: entry.role) else { continue }
                let trimmedText = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedText.isEmpty else { continue }
                let summarized = snippet(trimmedText, limit: maxCharsPerEntry)
                lines.append("- \(label): \(summarized)")
                fingerprintParts.append("\(entry.id.uuidString)|\(entry.role.rawValue)|\(trimmedText)")
            }
        } else {
            if let normalizedTitle {
                lines.append("- Thread: \(snippet(normalizedTitle, limit: 100))")
                fingerprintParts.append("title:\(normalizedTitle.lowercased())")
            }

            if let normalizedSessionSummary {
                lines.append("- Focus: \(snippet(normalizedSessionSummary, limit: 140))")
                fingerprintParts.append("summary:\(normalizedSessionSummary.lowercased())")
            }
        }

        let rawSummary = lines.joined(separator: "\n")
        let normalizedSummary = snippet(rawSummary, limit: maxTotalChars)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSummary.isEmpty else { return nil }

        let fingerprint = String(
            MemoryIdentifier.stableHexDigest(for: fingerprintParts.joined(separator: "\n")).prefix(16)
        )
        return SelectionSideAssistantChatSummarySnapshot(
            fingerprint: fingerprint,
            summary: normalizedSummary
        )
    }

    private static func roleLabel(for role: AssistantTranscriptRole) -> String? {
        switch role {
        case .user:
            return "User"
        case .assistant:
            return "Assistant"
        case .error:
            return "Error"
        case .system, .status, .tool, .permission:
            return nil
        }
    }

    private static func snippet(_ value: String, limit: Int) -> String {
        let normalized = MemoryTextNormalizer.normalizedBody(value)
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(max(0, limit - 3))) + "..."
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

private final class SelectionSideAssistantResponseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var assistantTextByEntryID: [UUID: String] = [:]

    func record(_ mutation: AssistantTranscriptMutation) {
        lock.lock()
        defer { lock.unlock() }
        switch mutation {
        case .reset:
            assistantTextByEntryID.removeAll()
            latestAssistantTextStorage = ""
        case .upsert(let entry, _):
            guard entry.role == .assistant else { return }
            assistantTextByEntryID[entry.id] = entry.text
            latestAssistantTextStorage = entry.text
        case .appendDelta(let id, _, let role, let delta, _, _, _):
            guard role == .assistant else { return }
            let updatedText = (assistantTextByEntryID[id] ?? "") + delta
            assistantTextByEntryID[id] = updatedText
            latestAssistantTextStorage = updatedText
        }
    }

    func latestAssistantText() -> String {
        lock.lock()
        defer { lock.unlock() }
        return latestAssistantTextStorage
    }

    private var latestAssistantTextStorage: String = ""
}

private final class SelectionSideAssistantContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<MemoryEntryExplanationResult, Never>?

    init(_ continuation: CheckedContinuation<MemoryEntryExplanationResult, Never>) {
        self.continuation = continuation
    }

    func resume(_ result: MemoryEntryExplanationResult) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: result)
    }
}

enum AssistantSessionSource: String, Codable, Sendable, CaseIterable {
    case openAssist
    case cli
    case vscode
    case appServer
    case other

    var label: String {
        switch self {
        case .openAssist: return "OpenAssist"
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

enum AssistantThreadArchitectureVersion: Int, Codable, Sendable {
    case legacy = 1
    case providerIndependentV2 = 2
}

enum AssistantConversationPersistenceKind: Int, Codable, Sendable {
    case transient = 0
    case snapshotOnly = 1
    case hybridJSONL = 2

    var persistsConversationHistory: Bool {
        self != .transient
    }
}

struct AssistantProviderBinding: Equatable, Codable, Sendable {
    var backend: AssistantRuntimeBackend
    var providerSessionID: String?
    var latestModelID: String?
    var latestInteractionMode: AssistantInteractionMode?
    var latestReasoningEffort: AssistantReasoningEffort?
    var latestServiceTier: String?
    var lastConnectedAt: Date?

    init(
        backend: AssistantRuntimeBackend,
        providerSessionID: String? = nil,
        latestModelID: String? = nil,
        latestInteractionMode: AssistantInteractionMode? = nil,
        latestReasoningEffort: AssistantReasoningEffort? = nil,
        latestServiceTier: String? = nil,
        lastConnectedAt: Date? = nil
    ) {
        self.backend = backend
        self.providerSessionID = providerSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        self.latestModelID = latestModelID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        self.latestInteractionMode = latestInteractionMode
        self.latestReasoningEffort = latestReasoningEffort
        self.latestServiceTier = latestServiceTier?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        self.lastConnectedAt = lastConnectedAt
    }
}

struct AssistantSessionSummary: Identifiable, Equatable, Codable, Sendable {
    let id: String
    var title: String
    var source: AssistantSessionSource
    var threadArchitectureVersion: AssistantThreadArchitectureVersion
    var conversationPersistence: AssistantConversationPersistenceKind
    var providerBackend: AssistantRuntimeBackend?
    var providerSessionID: String?
    var activeProvider: AssistantRuntimeBackend?
    var providerBindingsByBackend: [AssistantProviderBinding]
    var status: AssistantSessionStatus
    var parentThreadID: String?
    var cwd: String?
    var effectiveCWD: String?
    var createdAt: Date?
    var updatedAt: Date?
    var summary: String?
    var latestModel: String?
    var latestTaskMode: AssistantTaskMode?
    var latestInteractionMode: AssistantInteractionMode?
    var latestReasoningEffort: AssistantReasoningEffort?
    var latestServiceTier: String?
    var latestUserMessage: String?
    var latestAssistantMessage: String?
    var isArchived: Bool
    var archivedAt: Date?
    var archiveExpiresAt: Date?
    var archiveUsesDefaultRetention: Bool?
    var isTemporary: Bool
    var projectID: String?
    var projectName: String?
    var linkedProjectFolderPath: String?
    var projectFolderMissing: Bool

    init(
        id: String,
        title: String,
        source: AssistantSessionSource,
        threadArchitectureVersion: AssistantThreadArchitectureVersion = .legacy,
        conversationPersistence: AssistantConversationPersistenceKind = .snapshotOnly,
        providerBackend: AssistantRuntimeBackend? = nil,
        providerSessionID: String? = nil,
        activeProvider: AssistantRuntimeBackend? = nil,
        providerBindingsByBackend: [AssistantProviderBinding] = [],
        status: AssistantSessionStatus,
        parentThreadID: String? = nil,
        cwd: String? = nil,
        effectiveCWD: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        summary: String? = nil,
        latestModel: String? = nil,
        latestTaskMode: AssistantTaskMode? = nil,
        latestInteractionMode: AssistantInteractionMode? = nil,
        latestReasoningEffort: AssistantReasoningEffort? = nil,
        latestServiceTier: String? = nil,
        latestUserMessage: String? = nil,
        latestAssistantMessage: String? = nil,
        isArchived: Bool = false,
        archivedAt: Date? = nil,
        archiveExpiresAt: Date? = nil,
        archiveUsesDefaultRetention: Bool? = nil,
        isTemporary: Bool = false,
        projectID: String? = nil,
        projectName: String? = nil,
        linkedProjectFolderPath: String? = nil,
        projectFolderMissing: Bool = false
    ) {
        self.id = id
        self.title = title
        self.source = source
        self.threadArchitectureVersion = threadArchitectureVersion
        self.conversationPersistence = conversationPersistence
        self.providerBackend = providerBackend
        self.providerSessionID = providerSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        self.activeProvider = activeProvider
        self.providerBindingsByBackend = Self.normalizedProviderBindings(providerBindingsByBackend)
        self.status = status
        self.parentThreadID = parentThreadID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        self.cwd = cwd
        self.effectiveCWD = effectiveCWD
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.summary = summary
        self.latestModel = latestModel
        self.latestTaskMode = latestTaskMode
        self.latestInteractionMode = latestInteractionMode
        self.latestReasoningEffort = latestReasoningEffort
        self.latestServiceTier = latestServiceTier
        self.latestUserMessage = latestUserMessage
        self.latestAssistantMessage = latestAssistantMessage
        self.isArchived = isArchived
        self.archivedAt = archivedAt
        self.archiveExpiresAt = archiveExpiresAt
        self.archiveUsesDefaultRetention = archiveUsesDefaultRetention
        self.isTemporary = isTemporary
        self.projectID = projectID
        self.projectName = projectName
        self.linkedProjectFolderPath = linkedProjectFolderPath
        self.projectFolderMissing = projectFolderMissing
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case source
        case threadArchitectureVersion
        case conversationPersistence
        case providerBackend
        case providerSessionID
        case activeProvider
        case providerBindingsByBackend
        case status
        case parentThreadID
        case cwd
        case effectiveCWD
        case createdAt
        case updatedAt
        case summary
        case latestModel
        case latestTaskMode
        case latestInteractionMode
        case latestReasoningEffort
        case latestServiceTier
        case latestUserMessage
        case latestAssistantMessage
        case isArchived
        case archivedAt
        case archiveExpiresAt
        case archiveUsesDefaultRetention
        case isTemporary
        case projectID
        case projectName
        case linkedProjectFolderPath
        case projectFolderMissing
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            title: try container.decode(String.self, forKey: .title),
            source: try container.decodeIfPresent(AssistantSessionSource.self, forKey: .source) ?? .other,
            threadArchitectureVersion: try container.decodeIfPresent(
                AssistantThreadArchitectureVersion.self,
                forKey: .threadArchitectureVersion
            ) ?? .legacy,
            conversationPersistence: try container.decodeIfPresent(
                AssistantConversationPersistenceKind.self,
                forKey: .conversationPersistence
            ) ?? .snapshotOnly,
            providerBackend: try container.decodeIfPresent(AssistantRuntimeBackend.self, forKey: .providerBackend),
            providerSessionID: try container.decodeIfPresent(String.self, forKey: .providerSessionID),
            activeProvider: try container.decodeIfPresent(AssistantRuntimeBackend.self, forKey: .activeProvider),
            providerBindingsByBackend: try container.decodeIfPresent(
                [AssistantProviderBinding].self,
                forKey: .providerBindingsByBackend
            ) ?? [],
            status: try container.decodeIfPresent(AssistantSessionStatus.self, forKey: .status) ?? .unknown,
            parentThreadID: try container.decodeIfPresent(String.self, forKey: .parentThreadID),
            cwd: try container.decodeIfPresent(String.self, forKey: .cwd),
            effectiveCWD: try container.decodeIfPresent(String.self, forKey: .effectiveCWD),
            createdAt: try container.decodeIfPresent(Date.self, forKey: .createdAt),
            updatedAt: try container.decodeIfPresent(Date.self, forKey: .updatedAt),
            summary: try container.decodeIfPresent(String.self, forKey: .summary),
            latestModel: try container.decodeIfPresent(String.self, forKey: .latestModel),
            latestTaskMode: try container.decodeIfPresent(AssistantTaskMode.self, forKey: .latestTaskMode),
            latestInteractionMode: try container.decodeIfPresent(AssistantInteractionMode.self, forKey: .latestInteractionMode),
            latestReasoningEffort: try container.decodeIfPresent(AssistantReasoningEffort.self, forKey: .latestReasoningEffort),
            latestServiceTier: try container.decodeIfPresent(String.self, forKey: .latestServiceTier),
            latestUserMessage: try container.decodeIfPresent(String.self, forKey: .latestUserMessage),
            latestAssistantMessage: try container.decodeIfPresent(String.self, forKey: .latestAssistantMessage),
            isArchived: try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false,
            archivedAt: try container.decodeIfPresent(Date.self, forKey: .archivedAt),
            archiveExpiresAt: try container.decodeIfPresent(Date.self, forKey: .archiveExpiresAt),
            archiveUsesDefaultRetention: try container.decodeIfPresent(Bool.self, forKey: .archiveUsesDefaultRetention),
            isTemporary: try container.decodeIfPresent(Bool.self, forKey: .isTemporary) ?? false,
            projectID: try container.decodeIfPresent(String.self, forKey: .projectID),
            projectName: try container.decodeIfPresent(String.self, forKey: .projectName),
            linkedProjectFolderPath: try container.decodeIfPresent(String.self, forKey: .linkedProjectFolderPath),
            projectFolderMissing: try container.decodeIfPresent(Bool.self, forKey: .projectFolderMissing) ?? false
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(source, forKey: .source)
        try container.encode(threadArchitectureVersion, forKey: .threadArchitectureVersion)
        try container.encode(conversationPersistence, forKey: .conversationPersistence)
        try container.encodeIfPresent(providerBackend, forKey: .providerBackend)
        try container.encodeIfPresent(providerSessionID, forKey: .providerSessionID)
        try container.encodeIfPresent(activeProvider, forKey: .activeProvider)
        if !providerBindingsByBackend.isEmpty {
            try container.encode(providerBindingsByBackend, forKey: .providerBindingsByBackend)
        }
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(parentThreadID, forKey: .parentThreadID)
        try container.encodeIfPresent(cwd, forKey: .cwd)
        try container.encodeIfPresent(effectiveCWD, forKey: .effectiveCWD)
        try container.encodeIfPresent(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(summary, forKey: .summary)
        try container.encodeIfPresent(latestModel, forKey: .latestModel)
        try container.encodeIfPresent(latestTaskMode, forKey: .latestTaskMode)
        try container.encodeIfPresent(latestInteractionMode, forKey: .latestInteractionMode)
        try container.encodeIfPresent(latestReasoningEffort, forKey: .latestReasoningEffort)
        try container.encodeIfPresent(latestServiceTier, forKey: .latestServiceTier)
        try container.encodeIfPresent(latestUserMessage, forKey: .latestUserMessage)
        try container.encodeIfPresent(latestAssistantMessage, forKey: .latestAssistantMessage)
        try container.encode(isArchived, forKey: .isArchived)
        try container.encodeIfPresent(archivedAt, forKey: .archivedAt)
        try container.encodeIfPresent(archiveExpiresAt, forKey: .archiveExpiresAt)
        try container.encodeIfPresent(archiveUsesDefaultRetention, forKey: .archiveUsesDefaultRetention)
        try container.encode(isTemporary, forKey: .isTemporary)
        try container.encodeIfPresent(projectID, forKey: .projectID)
        try container.encodeIfPresent(projectName, forKey: .projectName)
        try container.encodeIfPresent(linkedProjectFolderPath, forKey: .linkedProjectFolderPath)
        try container.encode(projectFolderMissing, forKey: .projectFolderMissing)
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

    var supportsCatalogHistory: Bool {
        source != .cli || source == .openAssist
    }

    var isCanonicalThread: Bool {
        source == .openAssist
    }

    var isProviderIndependentThreadV2: Bool {
        isCanonicalThread && threadArchitectureVersion == .providerIndependentV2
    }

    var persistsConversationHistory: Bool {
        isProviderIndependentThreadV2 && conversationPersistence.persistsConversationHistory
    }

    var usesHybridConversationPersistence: Bool {
        persistsConversationHistory && conversationPersistence == .hybridJSONL
    }

    var activeProviderBackend: AssistantRuntimeBackend? {
        if isProviderIndependentThreadV2 {
            if let activeProvider {
                return activeProvider
            }
            return providerBindingsByBackend.first?.backend
        }
        return providerBackend
    }

    var activeProviderSessionID: String? {
        if isProviderIndependentThreadV2 {
            guard let activeProviderBackend else { return nil }
            return providerBinding(for: activeProviderBackend)?.providerSessionID
        }
        return providerSessionID
    }

    var modelID: String? {
        get {
            if isProviderIndependentThreadV2,
               let activeProviderBackend,
               let providerModelID = providerBinding(for: activeProviderBackend)?.latestModelID {
                return providerModelID
            }
            return latestModel
        }
        set { latestModel = newValue }
    }

    func providerBinding(for backend: AssistantRuntimeBackend) -> AssistantProviderBinding? {
        providerBindingsByBackend.first { $0.backend == backend }
    }

    mutating func setProviderBinding(_ binding: AssistantProviderBinding) {
        if let existingIndex = providerBindingsByBackend.firstIndex(where: { $0.backend == binding.backend }) {
            providerBindingsByBackend[existingIndex] = binding
        } else {
            providerBindingsByBackend.append(binding)
            providerBindingsByBackend.sort {
                $0.backend.shortDisplayName.localizedCaseInsensitiveCompare($1.backend.shortDisplayName) == .orderedAscending
            }
        }
    }

    private static func normalizedProviderBindings(
        _ bindings: [AssistantProviderBinding]
    ) -> [AssistantProviderBinding] {
        var ordered: [AssistantProviderBinding] = []
        var seen = Set<String>()

        for binding in bindings {
            let key = binding.backend.rawValue.lowercased()
            guard seen.insert(key).inserted else { continue }
            ordered.append(binding)
        }

        ordered.sort {
            $0.backend.shortDisplayName.localizedCaseInsensitiveCompare($1.backend.shortDisplayName) == .orderedAscending
        }
        return ordered
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

private func normalizedAssistantSessionKey(_ sessionID: String?) -> String? {
    sessionID?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .nonEmpty?
        .lowercased()
}

func assistantChildSessionIDs(
    parentSessionID: String,
    sessions: [AssistantSessionSummary]
) -> [String] {
    guard let normalizedParentID = normalizedAssistantSessionKey(parentSessionID) else {
        return []
    }

    var descendants: [String] = []
    var pending = [normalizedParentID]
    var seen = Set<String>([normalizedParentID])

    while let currentParentID = pending.popLast() {
        for session in sessions {
            guard let normalizedSessionID = normalizedAssistantSessionKey(session.id),
                  !seen.contains(normalizedSessionID),
                  normalizedAssistantSessionKey(session.parentThreadID) == currentParentID else {
                continue
            }
            seen.insert(normalizedSessionID)
            descendants.append(session.id)
            pending.append(normalizedSessionID)
        }
    }

    return descendants
}

func assistantEffectiveTemporarySessionIDs(
    storedTemporaryIDs: Set<String>,
    sessions: [AssistantSessionSummary]
) -> Set<String> {
    var effective = Set(storedTemporaryIDs.compactMap { normalizedAssistantSessionKey($0) })
    var didChange = true

    while didChange {
        didChange = false
        for session in sessions {
            guard let normalizedSessionID = normalizedAssistantSessionKey(session.id),
                  !effective.contains(normalizedSessionID),
                  let normalizedParentID = normalizedAssistantSessionKey(session.parentThreadID),
                  effective.contains(normalizedParentID) else {
                continue
            }
            effective.insert(normalizedSessionID)
            didChange = true
        }
    }

    return effective
}

func assistantShouldShowSessionInSidebar(
    _ session: AssistantSessionSummary,
    selectedSessionID: String?
) -> Bool {
    guard normalizedAssistantSessionKey(session.parentThreadID) != nil else {
        return true
    }
    return normalizedAssistantSessionKey(session.id) == normalizedAssistantSessionKey(selectedSessionID)
}

func assistantSessionSupportsCurrentThreadUI(_ session: AssistantSessionSummary) -> Bool {
    if session.isProviderIndependentThreadV2 {
        return true
    }

    switch session.source {
    case .cli, .vscode, .appServer:
        return true
    case .openAssist, .other:
        return false
    }
}

func assistantShouldListSessionInSidebar(
    _ session: AssistantSessionSummary,
    selectedSessionID: String?
) -> Bool {
    guard assistantShouldShowSessionInSidebar(session, selectedSessionID: selectedSessionID),
          assistantSessionSupportsCurrentThreadUI(session) else {
        return false
    }

    // Hide empty sessions unless they are the currently selected draft.
    // This keeps placeholder or partially recovered records from cluttering
    // the sidebar until they have real conversation history.
    if !session.hasConversationContent,
       normalizedAssistantSessionKey(session.id) != normalizedAssistantSessionKey(selectedSessionID) {
        return false
    }

    return true
}

func assistantShouldHideShadowProviderSession(
    _ session: AssistantSessionSummary,
    selectedSessionID: String?,
    canonicalThreadID: String?
) -> Bool {
    guard !session.isCanonicalThread,
          let normalizedCanonicalThreadID = normalizedAssistantSessionKey(canonicalThreadID),
          normalizedCanonicalThreadID != normalizedAssistantSessionKey(session.id) else {
        return false
    }

    // Keep the row visible if it is currently selected so the UI does not
    // suddenly drop the user's active thread while they are mid-inspection.
    return normalizedAssistantSessionKey(selectedSessionID)
        != normalizedAssistantSessionKey(session.id)
}

func assistantMergedSessionsForCleanup(
    liveSessions: [AssistantSessionSummary],
    catalogSessions: [AssistantSessionSummary],
    registrySessions: [AssistantSessionSummary]
) -> [AssistantSessionSummary] {
    var mergedSessions = liveSessions
    var existingIDs = Set(mergedSessions.compactMap { normalizedAssistantSessionKey($0.id) })

    for session in catalogSessions + registrySessions {
        guard let normalizedSessionID = normalizedAssistantSessionKey(session.id),
              !existingIDs.contains(normalizedSessionID) else {
            continue
        }
        existingIDs.insert(normalizedSessionID)
        mergedSessions.append(session)
    }

    return mergedSessions
}

func assistantShouldQueuePromptBehindActiveTurn(
    sessionHasActiveTurn: Bool,
    runtimeHasActiveTurn: Bool
) -> Bool {
    sessionHasActiveTurn || runtimeHasActiveTurn
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
        case .plan: return "Use the provider's plan mode and ask for approval when execution is needed"
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

    var isStructuredApprovalPrompt: Bool {
        guard hasStructuredUserInput, userInputQuestions.count == 1 else { return false }
        let normalized = Self.normalizedApprovalPromptText(
            userInputQuestions[0].prompt.nonEmpty ?? rationale ?? rawPayloadSummary ?? toolTitle
        )
        guard normalized.hasSuffix("?") else { return false }
        return normalized.hasPrefix("allow ")
            || normalized.hasPrefix("do you want ")
            || normalized.hasPrefix("would you like ")
            || normalized.hasPrefix("can i ")
            || normalized.hasPrefix("can codex ")
            || normalized.hasPrefix("should i ")
    }

    var displayRawPayloadSummary: String? {
        let summary = rawPayloadSummary?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let rationale = rationale?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        guard let summary else { return nil }
        guard summary.caseInsensitiveCompare(rationale ?? "") != .orderedSame else { return nil }
        return summary
    }

    var requiresDesktopAppConfirmation: Bool {
        let parts = (
            [toolTitle, rationale, rawPayloadSummary]
            + userInputQuestions.map(\.prompt)
        )
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty }
        let normalized = Self.normalizedApprovalPromptText(parts.joined(separator: " "))
        guard !normalized.isEmpty else { return false }

        let strongSignals = [
            "compose screen",
            "draft ready",
            "final click",
            "ready to post",
            "ready to publish",
            "ready to send"
        ]
        if strongSignals.contains(where: normalized.contains) {
            return true
        }

        let actionSignals = [
            "send",
            "post",
            "publish",
            "submit",
            "share",
            "tweet",
            "comment",
            "reply",
            "message",
            "email"
        ]
        let visualSignals = [
            "compose",
            "draft",
            "preview",
            "visible",
            "screen",
            "window",
            "browser",
            "app"
        ]

        guard actionSignals.contains(where: normalized.contains) else { return false }
        return visualSignals.contains(where: normalized.contains)
    }

    func structuredApprovalAnswers(approved: Bool) -> [String: [String]] {
        guard let question = userInputQuestions.first else { return [:] }
        if let matchingOption = Self.matchingStructuredApprovalOption(
            in: question.options,
            approved: approved
        ) {
            return [question.id: [matchingOption.label]]
        }
        return [question.id: [approved ? "Yes" : "No"]]
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

    private static func matchingStructuredApprovalOption(
        in options: [AssistantUserInputQuestionOption],
        approved: Bool
    ) -> AssistantUserInputQuestionOption? {
        let preferredTerms = approved
            ? ["allow", "accept", "approve", "approved", "yes", "true"]
            : ["decline", "deny", "reject", "rejected", "no", "false"]
        return options.first { option in
            let normalized = normalizedApprovalPromptText(option.label)
            return preferredTerms.contains(where: { normalized == $0 || normalized.contains($0) })
        }
    }

    private static func normalizedApprovalPromptText(_ text: String?) -> String {
        guard let text else { return "" }
        let directionalMarks = CharacterSet(charactersIn:
            "\u{061C}\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}"
        )
        let filtered = String(String.UnicodeScalarView(text.unicodeScalars.filter {
            !directionalMarks.contains($0)
        }))
        return filtered
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

struct AssistantInstallGuidance: Equatable, Sendable {
    var backend: AssistantRuntimeBackend
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

    static func placeholder(for backend: AssistantRuntimeBackend) -> AssistantInstallGuidance {
        AssistantInstallGuidance(
            backend: backend,
            codexDetected: false,
            brewDetected: false,
            npmDetected: false,
            codexPath: nil,
            brewPath: nil,
            npmPath: nil,
            primaryTitle: "Checking \(backend.shortDisplayName)…",
            primaryDetail: "Open Assist is looking for \(backend.displayName) on this Mac.",
            installCommands: [],
            loginCommands: backend.loginCommands,
            docsURL: backend.docsURL
        )
    }

    static let placeholder = AssistantInstallGuidance.placeholder(for: .codex)
}

enum AssistantEnvironmentState {
    case missingCodex
    case needsLogin
    case ready
    case failed

    var headline: String {
        switch self {
        case .missingCodex: return "Install assistant runtime"
        case .needsLogin: return "Sign in to assistant runtime"
        case .ready: return "Assistant is ready"
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
    var isInstalled: Bool = true

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
    let latestRemoteAttentionEvent: AssistantRemoteAttentionEvent?
    let hudState: AssistantHUDState?
    let hasActiveTurn: Bool
    let toolCalls: [AssistantToolCallState]
    let recentToolCalls: [AssistantToolCallState]
    let imageDelivery: AssistantRemoteImageDelivery?
    let activeTurnID: String?
    let pendingOutgoingMessage: AssistantPendingOutgoingMessage?
    let awaitingAssistantStart: Bool
    let queuedPromptCount: Int

    init(
        session: AssistantSessionSummary,
        transcriptEntries: [AssistantTranscriptEntry],
        pendingPermissionRequest: AssistantPermissionRequest?,
        latestRemoteAttentionEvent: AssistantRemoteAttentionEvent? = nil,
        hudState: AssistantHUDState?,
        hasActiveTurn: Bool,
        toolCalls: [AssistantToolCallState],
        recentToolCalls: [AssistantToolCallState],
        imageDelivery: AssistantRemoteImageDelivery?,
        activeTurnID: String? = nil,
        pendingOutgoingMessage: AssistantPendingOutgoingMessage? = nil,
        awaitingAssistantStart: Bool = false,
        queuedPromptCount: Int = 0
    ) {
        self.session = session
        self.transcriptEntries = transcriptEntries
        self.pendingPermissionRequest = pendingPermissionRequest
        self.latestRemoteAttentionEvent = latestRemoteAttentionEvent
        self.hudState = hudState
        self.hasActiveTurn = hasActiveTurn
        self.toolCalls = toolCalls
        self.recentToolCalls = recentToolCalls
        self.imageDelivery = imageDelivery
        self.activeTurnID = activeTurnID
        self.pendingOutgoingMessage = pendingOutgoingMessage
        self.awaitingAssistantStart = awaitingAssistantStart
        self.queuedPromptCount = queuedPromptCount
    }
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

enum AssistantHistoryMutationKind: String, Equatable, Codable, Sendable {
    case undo
    case edit
    case checkpoint
}

struct AssistantHistoryRollbackSnapshot: Equatable, Codable, Sendable {
    let memoryDocumentMarkdown: String?
    let removedSuggestions: [AssistantMemorySuggestion]
    let removedAcceptedEntries: [AssistantMemoryEntry]
    let agentProfile: ConversationAgentProfileRecord?
    let agentEntities: ConversationAgentEntitiesRecord?
    let agentPreferences: ConversationAgentPreferencesRecord?
}

struct AssistantHistoryFutureState: Equatable, Codable, Sendable, Identifiable {
    let restoreAnchorID: String
    let title: String
    let snapshotID: String
    let checkpointPosition: Int
    let currentAnchorIDAfterRestore: String?
    let composerPrompt: String
    let composerAttachments: [AssistantAttachment]

    var id: String { snapshotID }
}

struct AssistantHistoryRestoreItem: Equatable, Identifiable {
    let id: String
    let anchorID: String
    let title: String
}

struct AssistantHistoryBranchState: Equatable, Codable, Sendable {
    let kind: AssistantHistoryMutationKind
    let sessionID: String
    let currentAnchorID: String
    let currentCheckpointPosition: Int
    let currentPrompt: String
    let currentAttachments: [AssistantAttachment]
    let futureStates: [AssistantHistoryFutureState]

    var bannerText: String? {
        switch kind {
        case .edit:
            return "Editing your last message below. Change it, then press Send."
        case .undo:
            return "That message is back in the text box below. Change it, then press Send."
        case .checkpoint:
            return "Code rewind is ready. The restored request is in the text box below. Change it, then press Send."
        }
    }

    var canRedo: Bool {
        !futureStates.isEmpty
    }
}

struct AssistantHistoryActionAvailability: Equatable {
    let anchorID: String
    let canUndo: Bool
    let canEdit: Bool
}

enum AssistantHistoryMutationError: LocalizedError {
    case missingRepository
    case invalidCheckpointTarget
    case missingCheckpointAnchor

    var errorDescription: String? {
        switch self {
        case .missingRepository:
            return "Tracked coding is unavailable because this thread is not inside a Git repository."
        case .invalidCheckpointTarget:
            return "Open Assist could not find the saved checkpoint needed for this rewind."
        case .missingCheckpointAnchor:
            return "Open Assist could not find the original request for that checkpoint."
        }
    }
}

enum AssistantCodeCheckpointPhase: String, Codable, Sendable {
    case before
    case after
}

enum AssistantCodeCheckpointChangeKind: String, Codable, Sendable {
    case added
    case modified
    case deleted
    case typeChanged
    case changed

    var label: String {
        switch self {
        case .added:
            return "Added"
        case .modified:
            return "Modified"
        case .deleted:
            return "Deleted"
        case .typeChanged:
            return "Type Changed"
        case .changed:
            return "Changed"
        }
    }
}

enum AssistantCodeCheckpointTurnStatus: String, Codable, Sendable {
    case completed
    case interrupted
    case failed
}

enum AssistantCodeTrackingAvailability: String, Codable, Sendable {
    case available
    case unavailable
    case disabled
}

struct AssistantCodeCheckpointFile: Identifiable, Codable, Equatable, Sendable {
    let path: String
    let changeKind: AssistantCodeCheckpointChangeKind
    let beforeWorktree: GitCheckpointPathState
    let afterWorktree: GitCheckpointPathState
    let beforeIndex: GitCheckpointPathState
    let afterIndex: GitCheckpointPathState
    let isBinary: Bool

    var id: String { path }
}

struct AssistantCodeCheckpointSummary: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let checkpointNumber: Int
    let createdAt: Date
    let turnStatus: AssistantCodeCheckpointTurnStatus
    let summary: String
    let patch: String
    let changedFiles: [AssistantCodeCheckpointFile]
    let ignoredTouchedPaths: [String]
    let beforeSnapshot: GitCheckpointSnapshot
    let afterSnapshot: GitCheckpointSnapshot
    var associatedMessageID: String? = nil
    var associatedTurnID: String? = nil
    var associatedUserMessageID: String? = nil
    var associatedUserAnchorID: String? = nil

    var changedFileCount: Int {
        changedFiles.count
    }

    var hasIgnoredCoverageWarning: Bool {
        !ignoredTouchedPaths.isEmpty
    }
}

struct AssistantPendingCodeCheckpointBaseline: Equatable, Sendable {
    let sessionID: String
    let checkpointID: String
    let repository: GitCheckpointRepositoryContext
    let beforeSnapshot: GitCheckpointSnapshot
    let startedAt: Date
}

struct AssistantCodeRestoreGuardResult: Equatable, Sendable {
    let isAllowed: Bool
    let message: String?

    static let allowed = AssistantCodeRestoreGuardResult(
        isAllowed: true,
        message: nil
    )
}

struct AssistantCodeTrackingState: Codable, Equatable, Sendable {
    let sessionID: String
    var availability: AssistantCodeTrackingAvailability
    var repoRootPath: String?
    var repoLabel: String?
    var checkpoints: [AssistantCodeCheckpointSummary]
    var currentCheckpointPosition: Int
    var historyBranchState: AssistantHistoryBranchState?

    static func empty(sessionID: String) -> AssistantCodeTrackingState {
        AssistantCodeTrackingState(
            sessionID: sessionID,
            availability: .unavailable,
            repoRootPath: nil,
            repoLabel: nil,
            checkpoints: [],
            currentCheckpointPosition: -1,
            historyBranchState: nil
        )
    }

    var currentCheckpoint: AssistantCodeCheckpointSummary? {
        guard checkpoints.indices.contains(currentCheckpointPosition) else { return nil }
        return checkpoints[currentCheckpointPosition]
    }

    var canUndo: Bool {
        availability == .available
            && currentCheckpointPosition >= 0
            && currentCheckpointPosition == checkpoints.count - 1
    }

    var canRedo: Bool {
        availability == .available && currentCheckpointPosition + 1 < checkpoints.count
    }

    var latestCheckpoint: AssistantCodeCheckpointSummary? {
        checkpoints.last
    }
}

struct AssistantCodeReviewPanelState: Equatable, Sendable {
    let sessionID: String
    let repoRootPath: String
    let repoLabel: String
    let checkpoints: [AssistantCodeCheckpointSummary]
    let currentCheckpointPosition: Int
    let selectedCheckpointID: String
}

enum AssistantProjectFilter: Equatable, Sendable {
    case folder(String)
    case project(String)

    var id: String {
        switch self {
        case .folder(let id), .project(let id):
            return id
        }
    }
}

typealias AssistantFeatureController = AssistantStore

@MainActor
final class AssistantStore: ObservableObject {
    static let shared = AssistantStore()
    private static let timelineCacheSaveDebounceInterval: TimeInterval = 0.35
    private static let trackedCodeRecoveryCatalogCacheSuccessTTL: TimeInterval = 60
    private static let trackedCodeRecoveryCatalogCacheFailureTTL: TimeInterval = 10
    private static let maxConcurrentLiveSessions = 6
    private static let sidebarInitialSessionsLimit = 30
    private static let sidebarSessionsBatchSize = 20
    private static let sidebarSessionsPrefetchBuffer = 40
    private enum HistoryLoading {
        static let initialTimelineLimit = 32
        static let initialTranscriptLimit = 24
        static let timelineBatchSize = 48
        static let transcriptBatchSize = 36
        static let recentTimelineChunkLimit = 14
        static let recentTranscriptChunkLimit = 12
    }

    private struct SessionCatalogCWDCacheEntry {
        let cwd: String?
        let expiresAt: Date

        var isExpired: Bool {
            Date() >= expiresAt
        }
    }

    @Published private(set) var runtimeHealth: AssistantRuntimeHealth = .idle
    @Published private(set) var installGuidance: AssistantInstallGuidance = .placeholder
    @Published private(set) var installGuidanceByBackend: [AssistantRuntimeBackend: AssistantInstallGuidance] = [:]
    @Published private(set) var permissions: AssistantPermissionSnapshot = .unknown
    @Published private(set) var sessions: [AssistantSessionSummary] = []
    @Published private(set) var projects: [AssistantProject] = []
    @Published var visibleSessionsLimit: Int = AssistantStore.sidebarInitialSessionsLimit

    func loadMoreSessions() {
        let nextLimit = Self.nextVisibleSessionsLimit(currentLimit: visibleSessionsLimit)
        visibleSessionsLimit = nextLimit

        guard Self.shouldPrefetchMoreSessions(
            loadedCount: sessions.count,
            visibleLimit: nextLimit
        ) else {
            return
        }

        let requestedLimit = Self.effectiveSessionRefreshLimit(
            requestedLimit: nextLimit,
            visibleLimit: nextLimit
        )
        Task { [weak self] in
            await self?.refreshSessions(limit: requestedLimit)
        }
    }

    static func nextVisibleSessionsLimit(currentLimit: Int) -> Int {
        max(sidebarInitialSessionsLimit, currentLimit + sidebarSessionsBatchSize)
    }

    static func shouldPrefetchMoreSessions(loadedCount: Int, visibleLimit: Int) -> Bool {
        loadedCount <= max(sidebarInitialSessionsLimit, visibleLimit + sidebarSessionsPrefetchBuffer)
    }

    static func effectiveSessionRefreshLimit(requestedLimit: Int, visibleLimit: Int) -> Int {
        max(200, requestedLimit, visibleLimit + sidebarSessionsPrefetchBuffer)
    }

    static func updatedOwnedSessionIDs(
        existing: [String],
        adding sessionID: String?
    ) -> [String] {
        guard let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return normalizedOwnedSessionIDs(existing)
        }

        var updated = normalizedOwnedSessionIDs(existing)
        updated.removeAll { $0.caseInsensitiveCompare(sessionID) == .orderedSame }
        updated.insert(sessionID, at: 0)
        return updated
    }

    static func normalizedOwnedSessionIDs(_ sessionIDs: [String]) -> [String] {
        var seen = Set<String>()
        var normalized: [String] = []

        for candidate in sessionIDs {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let lowered = trimmed.lowercased()
            guard seen.insert(lowered).inserted else { continue }
            normalized.append(trimmed)
        }

        return normalized
    }

    var assistantBackend: AssistantRuntimeBackend {
        Self.resolvedDefaultAssistantBackend(
            preferred: settings.assistantBackend,
            guidanceByBackend: installGuidanceByBackend
        )
    }

    var visibleAssistantBackend: AssistantRuntimeBackend {
        selectedSession.map(backend(for:)) ?? assistantBackend
    }

    var selectableAssistantBackends: [AssistantRuntimeBackend] {
        Self.resolvedSelectableAssistantBackends(
            preferred: settings.assistantBackend,
            guidanceByBackend: installGuidanceByBackend
        )
    }

    var assistantBackendName: String {
        assistantBackend.displayName
    }

    var visibleAssistantBackendName: String {
        visibleAssistantBackend.displayName
    }

    var isSelectedSessionBackendPinned: Bool {
        guard let selectedSession else { return false }
        return Self.shouldPinBackendSelection(
            for: selectedSession,
            hasActiveTurn: sessionActivitySnapshot(for: selectedSession.id).hasActiveTurn
        )
    }

    var selectedSessionBackendHelpText: String? {
        guard let selectedSession else { return nil }
        if selectedSession.isProviderIndependentThreadV2 {
            if sessionActivitySnapshot(for: selectedSession.id).hasActiveTurn {
                return "Wait for the current response to finish before switching providers."
            }
            return "This chat keeps one shared memory. You can switch providers between turns."
        }
        return "This thread stays on \(visibleAssistantBackend.shortDisplayName). Start a new thread to switch backends."
    }

    var assistantInstallActionTitle: String {
        assistantBackend.installActionTitle
    }

    var assistantDocsActionTitle: String {
        assistantBackend.docsActionTitle
    }

    var assistantLoginActionTitle: String {
        assistantBackend.loginActionTitle
    }

    var shouldOfferCopilotSetupCard: Bool {
        guidance(for: .copilot).codexDetected == false
    }

    func guidance(for backend: AssistantRuntimeBackend) -> AssistantInstallGuidance {
        if installGuidance.backend == backend {
            return installGuidance
        }
        return installGuidanceByBackend[backend] ?? .placeholder(for: backend)
    }

    func selectAssistantBackend(_ backend: AssistantRuntimeBackend) {
        Task { @MainActor [weak self] in
            _ = await self?.switchAssistantBackend(backend)
        }
    }

    @discardableResult
    func switchAssistantBackend(_ backend: AssistantRuntimeBackend) async -> Bool {
        guard selectableAssistantBackends.contains(backend) else {
            return false
        }
        if let selectedSession,
           selectedSession.isProviderIndependentThreadV2 {
            return await switchProvider(for: selectedSession.id, to: backend)
        }
        guard settings.assistantBackend != backend else { return false }
        let previousBackend = settings.assistantBackend
        applyAssistantBackendSelectionState(backend)
        var runtimesByID: [ObjectIdentifier: CodexAssistantRuntime] = [:]
        for candidate in [rootRuntime] + Array(sessionRuntimesBySessionID.values) {
            runtimesByID[ObjectIdentifier(candidate)] = candidate
        }
        for runtime in runtimesByID.values {
            await runtime.stop()
            runtime.clearCachedEnvironmentState()
            runtime.backend = backend
        }
        await refreshEnvironment(permissions: permissions)
        await refreshSessions()
        if previousBackend == .ollamaLocal, backend != .ollamaLocal {
            await stopManagedLocalOllamaRuntimeIfIdle()
        }
        return true
    }

    private func applyAssistantBackendSelectionState(_ backend: AssistantRuntimeBackend) {
        cancelSelectedSessionWarmup()
        // Clear session selection first so its deferred didSet work (Fix 2)
        // runs after the bulk reset below has already zeroed derived state,
        // making the sync a cheap no-op.
        selectedSessionID = nil
        settings.assistantBackend = backend
        let normalizedPreferredModelID = Self.normalizedStartupPreferredModelID(
            for: backend,
            storedModelID: settings.assistantPreferredModelID.nonEmpty
        )
        if settings.assistantPreferredModelID.nonEmpty != normalizedPreferredModelID {
            settings.assistantPreferredModelID = normalizedPreferredModelID ?? ""
        }
        runtime.backend = backend
        installGuidance = .placeholder(for: backend)
        accountSnapshot = .signedOut
        visibleProviderSurfaceBackend = nil
        availableModels = []
        selectedModelID = nil
        runtimeHealth = .idle
        pendingPermissionRequest = nil
        sessions = []
        toolCalls = []
        recentToolCalls = []
        transcript = []
        timelineItems = []
        cachedRenderItems = []
        transcriptSessionID = nil
        timelineSessionID = nil
        planEntries = []
        tokenUsage = .empty
        rateLimits = .empty
        subagents = []
        proposedPlan = nil
        proposedPlanSessionID = nil
        lastStatusMessage = nil
    }

    static func resolvedDefaultAssistantBackend(
        preferred: AssistantRuntimeBackend,
        guidanceByBackend: [AssistantRuntimeBackend: AssistantInstallGuidance]
    ) -> AssistantRuntimeBackend {
        guard guidanceByBackend.count == AssistantRuntimeBackend.allCases.count else {
            return preferred
        }

        let detectedBackends = AssistantRuntimeBackend.allCases.filter { backend in
            guidanceByBackend[backend]?.codexDetected == true
        }

        if detectedBackends.contains(preferred) || preferred == .ollamaLocal {
            return preferred
        }

        return detectedBackends.first ?? .codex
    }

    static func resolvedSelectableAssistantBackends(
        preferred: AssistantRuntimeBackend,
        guidanceByBackend: [AssistantRuntimeBackend: AssistantInstallGuidance]
    ) -> [AssistantRuntimeBackend] {
        guard guidanceByBackend.count == AssistantRuntimeBackend.allCases.count else {
            return AssistantRuntimeBackend.allCases
        }

        let detectedBackends = AssistantRuntimeBackend.allCases.filter { backend in
            guidanceByBackend[backend]?.codexDetected == true
        }

        if detectedBackends.isEmpty {
            let defaultBackend = resolvedDefaultAssistantBackend(
                preferred: preferred,
                guidanceByBackend: guidanceByBackend
            )
            if defaultBackend == .ollamaLocal {
                return [.ollamaLocal]
            }
            return [defaultBackend, .ollamaLocal]
        }

        if detectedBackends.contains(.ollamaLocal) {
            return detectedBackends
        }
        return detectedBackends + [.ollamaLocal]
    }

    @discardableResult
    private func switchProvider(
        for threadID: String,
        to backend: AssistantRuntimeBackend
    ) async -> Bool {
        guard let sessionIndex = sessions.firstIndex(where: { sessionsMatch($0.id, threadID) }) else {
            return false
        }

        let hasActiveTurn = sessionActivitySnapshot(for: threadID).hasActiveTurn
        guard !hasActiveTurn else {
            lastStatusMessage = "Wait for the current response to finish before switching providers."
            return false
        }

        var session = sessions[sessionIndex]
        guard session.isProviderIndependentThreadV2 else {
            return false
        }

        let previousBackend = session.activeProviderBackend
        settings.assistantBackend = backend

        if session.providerBinding(for: backend) == nil {
            session.setProviderBinding(
                AssistantProviderBinding(
                    backend: backend,
                    latestModelID: nil,
                    latestInteractionMode: interactionMode,
                    latestReasoningEffort: reasoningEffort,
                    latestServiceTier: fastModeEnabled ? "fast" : nil,
                    lastConnectedAt: Date()
                )
            )
        }

        session.activeProvider = backend
        sessions[sessionIndex] = session
        persistManagedSessionsSnapshot()

        restoreVisibleProviderState(for: session)
        let hasWarmModels = hasCachedModels(threadID: threadID, backend: backend)
        isLoadingModels = !hasWarmModels
        Task { @MainActor [weak self] in
            await self?.refreshProviderSwitchSurfaceIfStillCurrent(
                threadID: threadID,
                backend: backend
            )
        }

        if previousBackend == .ollamaLocal, backend != .ollamaLocal {
            await stopManagedLocalOllamaRuntimeIfIdle()
        }

        if previousBackend != backend {
            lastStatusMessage = "Switched this chat to \(backend.displayName)."
        }
        return previousBackend != backend
    }

    static func shouldPinBackendSelection(
        for session: AssistantSessionSummary?,
        hasActiveTurn: Bool
    ) -> Bool {
        guard let session else { return false }
        guard session.isProviderIndependentThreadV2 else { return true }
        return hasActiveTurn
    }

    static func shouldApplyProviderSessionChange(
        for session: AssistantSessionSummary,
        runtimeBackend: AssistantRuntimeBackend,
        providerSessionID: String?
    ) -> Bool {
        let normalizedProviderSessionID = providerSessionID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty

        guard session.isCanonicalThread else {
            return true
        }

        guard normalizedProviderSessionID != nil else {
            return false
        }

        if session.isProviderIndependentThreadV2,
           let activeProviderBackend = session.activeProviderBackend,
           activeProviderBackend != runtimeBackend {
            return false
        }

        return true
    }

    static func shouldApplyVisibleRuntimeRefreshResult(
        requestedBackend: AssistantRuntimeBackend,
        currentVisibleBackend: AssistantRuntimeBackend,
        runtimeBackend: AssistantRuntimeBackend
    ) -> Bool {
        requestedBackend == currentVisibleBackend && requestedBackend == runtimeBackend
    }

    private func refreshProviderSwitchSurfaceIfStillCurrent(
        threadID: String,
        backend: AssistantRuntimeBackend
    ) async {
        guard sessionsMatch(selectedSessionID, threadID),
              let currentSession = sessions.first(where: { sessionsMatch($0.id, threadID) }),
              currentSession.activeProviderBackend == backend else {
            return
        }

        let selectedRuntime = ensureRuntime(for: threadID)
        await ensureRuntimeBackend(selectedRuntime, matches: backend)

        guard sessionsMatch(selectedSessionID, threadID),
              let refreshedSession = sessions.first(where: { sessionsMatch($0.id, threadID) }),
              refreshedSession.activeProviderBackend == backend else {
            return
        }

        await refreshEnvironment(permissions: permissions)
        await reloadSelectedSessionHistoryIfNeeded(force: true)
        scheduleSelectedSessionWarmupIfNeeded()
    }

    private func cancelSelectedSessionWarmup() {
        selectedSessionWarmupTask?.cancel()
        selectedSessionWarmupTask = nil
    }

    private func scheduleSelectedSessionWarmupIfNeeded() {
        cancelSelectedSessionWarmup()

        guard let selectedSession = selectedSession else { return }
        let selectedThreadID = selectedSession.id

        selectedSessionWarmupTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            await self.warmSelectedSessionIfStillCurrent(selectedThreadID)
            if self.selectedSessionWarmupTask?.isCancelled == false,
               self.sessionsMatch(self.selectedSessionID, selectedThreadID) {
                self.selectedSessionWarmupTask = nil
            }
        }
    }

    private func warmSelectedSessionIfStillCurrent(_ threadID: String) async {
        guard !Task.isCancelled,
              sessionsMatch(selectedSessionID, threadID),
              let session = sessions.first(where: { sessionsMatch($0.id, threadID) }) else {
            return
        }

        let activeBackend = backend(for: session)
        let selectedRuntime = ensureRuntime(for: threadID)

        _ = await silentlyResumeStoredProviderSession(
            using: selectedRuntime,
            session: session,
            backend: activeBackend,
            suppressErrors: true
        )

        guard !Task.isCancelled,
              sessionsMatch(selectedSessionID, threadID) else {
            return
        }

        await warmCachedModelsIfNeeded(
            for: session,
            backend: activeBackend,
            runtime: selectedRuntime,
            allowNewSessionCreation: false
        )

        for backend in AssistantRuntimeBackend.allCases where backend != activeBackend {
            guard !Task.isCancelled,
                  sessionsMatch(selectedSessionID, threadID) else {
                return
            }

            await warmCachedModelsIfNeeded(
                for: session,
                backend: backend,
                runtime: nil,
                allowNewSessionCreation: false
            )
        }
    }

    private func warmCachedModelsIfNeeded(
        for session: AssistantSessionSummary,
        backend: AssistantRuntimeBackend,
        runtime: CodexAssistantRuntime?,
        allowNewSessionCreation: Bool
    ) async {
        guard !hasCachedModels(threadID: session.id, backend: backend) else { return }

        switch backend {
        case .codex:
            let warmRuntime = runtime ?? makeBackgroundWarmupRuntime(
                preferredSessionID: session.id,
                backend: backend
            )
            let shouldStopRuntime = runtime == nil
            let guidance = await installSupport.inspect(backend: backend)
            guard guidance.codexDetected else {
                if shouldStopRuntime {
                    await warmRuntime.stop()
                }
                return
            }

            await ensureRuntimeBackend(warmRuntime, matches: backend)
            do {
                _ = try await warmRuntime.refreshEnvironment(codexPath: guidance.codexPath)
                if shouldStopRuntime {
                    await waitForCachedModels(threadID: session.id, backend: backend)
                }
            } catch {
                if shouldStopRuntime {
                    await warmRuntime.stop()
                }
                return
            }

            if shouldStopRuntime {
                await warmRuntime.stop()
            }
        case .copilot:
            guard allowNewSessionCreation
                || providerSessionID(for: session, backend: backend) != nil
                || !(providerAvailableModelsByBackend[backend] ?? []).isEmpty else {
                return
            }

            if runtime != nil {
                _ = await silentlyResumeStoredProviderSession(
                    using: runtime ?? ensureRuntime(for: session.id),
                    session: session,
                    backend: backend,
                    suppressErrors: true
                )
                return
            }

            guard providerSessionID(for: session, backend: backend) != nil else { return }
            let warmRuntime = makeBackgroundWarmupRuntime(
                preferredSessionID: session.id,
                backend: backend
            )

            _ = await silentlyResumeStoredProviderSession(
                using: warmRuntime,
                session: session,
                backend: backend,
                suppressErrors: true
            )
            await waitForCachedModels(threadID: session.id, backend: backend)
            await warmRuntime.stop()
        case .claudeCode:
            let warmRuntime = runtime ?? makeBackgroundWarmupRuntime(
                preferredSessionID: session.id,
                backend: backend
            )
            let shouldStopRuntime = runtime == nil
            let guidance = await installSupport.inspect(backend: backend)
            guard guidance.codexDetected else {
                if shouldStopRuntime {
                    await warmRuntime.stop()
                }
                return
            }

            await ensureRuntimeBackend(warmRuntime, matches: backend)
            do {
                _ = try await warmRuntime.refreshEnvironment(codexPath: guidance.codexPath)
                if shouldStopRuntime {
                    await waitForCachedModels(threadID: session.id, backend: backend)
                }
            } catch {
                if shouldStopRuntime {
                    await warmRuntime.stop()
                }
                return
            }

            if shouldStopRuntime {
                await warmRuntime.stop()
            }
        case .ollamaLocal:
            let warmRuntime = runtime ?? makeBackgroundWarmupRuntime(
                preferredSessionID: session.id,
                backend: backend
            )
            let shouldStopRuntime = runtime == nil
            let guidance = await installSupport.inspect(backend: backend)
            guard guidance.codexDetected else {
                if shouldStopRuntime {
                    await warmRuntime.stop()
                }
                return
            }

            await ensureRuntimeBackend(warmRuntime, matches: backend)
            do {
                _ = try await warmRuntime.refreshEnvironment(codexPath: guidance.codexPath)
                if shouldStopRuntime {
                    await waitForCachedModels(threadID: session.id, backend: backend)
                }
            } catch {
                if shouldStopRuntime {
                    await warmRuntime.stop()
                }
                return
            }

            if shouldStopRuntime {
                await warmRuntime.stop()
            }
        }
    }

    private func waitForCachedModels(
        threadID: String,
        backend: AssistantRuntimeBackend,
        timeoutNanoseconds: UInt64 = 3_000_000_000
    ) async {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        while !Task.isCancelled {
            if hasCachedModels(threadID: threadID, backend: backend) {
                return
            }

            let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt
            if elapsed >= timeoutNanoseconds {
                return
            }

            try? await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    private func makeBackgroundWarmupRuntime(
        preferredSessionID: String,
        backend: AssistantRuntimeBackend
    ) -> CodexAssistantRuntime {
        let runtime = runtimeFactory()
        runtime.backend = backend
        bindRuntimeCallbacks(runtime, preferredSessionID: preferredSessionID)
        runtime.onHealthUpdate = nil
        runtime.onTranscript = nil
        runtime.onTranscriptMutation = nil
        runtime.onTimelineMutation = nil
        runtime.onHUDUpdate = nil
        runtime.onPlanUpdate = nil
        runtime.onToolCallUpdate = nil
        runtime.onPermissionRequest = nil
        runtime.onSessionChange = nil
        runtime.onStatusMessage = nil
        runtime.onTokenUsageUpdate = nil
        runtime.onSubagentUpdate = nil
        runtime.onProposedPlan = nil
        runtime.onModeRestriction = nil
        runtime.onTurnCompletion = nil
        runtime.onTitleRequest = nil
        return runtime
    }

    var selectedProjectFilterID: String? {
        selectedProjectFilter?.id
    }

    var selectedProject: AssistantProject? {
        guard case let .project(projectID)? = selectedProjectFilter else {
            return nil
        }
        return visibleLeafProjects.first(where: {
            $0.id.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(projectID) == .orderedSame
        })
    }

    var selectedFolder: AssistantProject? {
        guard case let .folder(folderID)? = selectedProjectFilter else {
            return nil
        }
        return visibleFolders.first(where: {
            $0.id.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(folderID) == .orderedSame
        })
    }

    var visibleProjects: [AssistantProject] {
        projectStore.visibleProjects()
    }

    var visibleFolders: [AssistantProject] {
        visibleProjects.filter(\.isFolder)
    }

    var visibleLeafProjects: [AssistantProject] {
        visibleProjects.filter(\.isProject)
    }

    var hiddenProjects: [AssistantProject] {
        projects.filter { $0.isHidden }
    }

    private var visibleSidebarProjectSessions: [AssistantSessionSummary] {
        let visibleProjectIDs = Set(visibleLeafProjects.map { $0.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        return sessions.filter { session in
            guard let projectID = session.projectID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty?.lowercased() else {
                return true
            }
            return visibleProjectIDs.contains(projectID)
        }
    }

    var visibleSidebarSessionsIgnoringProjectFilter: [AssistantSessionSummary] {
        visibleSidebarProjectSessions.filter { session in
            !session.isArchived
                && assistantShouldListSessionInSidebar(session, selectedSessionID: selectedSessionID)
                && !assistantShouldHideShadowProviderSession(
                    session,
                    selectedSessionID: selectedSessionID,
                    canonicalThreadID: canonicalThreadID(forProviderSessionID: session.id)
                )
        }
    }

    private var projectFilteredSidebarSessions: [AssistantSessionSummary] {
        let projectFilteredSessions: [AssistantSessionSummary]
        switch selectedProjectFilter {
        case .project(let projectID):
            projectFilteredSessions = visibleSidebarProjectSessions.filter {
                $0.projectID?.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare(projectID) == .orderedSame
            }
        case .folder(let folderID):
            let descendantProjectIDs = projectStore.descendantProjectIDs(ofFolderID: folderID)
            let normalizedDescendantProjectIDs = Set(
                descendantProjectIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            )
            projectFilteredSessions = visibleSidebarProjectSessions.filter {
                guard let projectID = $0.projectID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty?.lowercased() else {
                    return false
                }
                return normalizedDescendantProjectIDs.contains(projectID)
            }
        case nil:
            projectFilteredSessions = visibleSidebarProjectSessions
        }

        return projectFilteredSessions
    }

    var visibleSidebarSessions: [AssistantSessionSummary] {
        projectFilteredSidebarSessions.filter { session in
            !session.isArchived
                && assistantShouldListSessionInSidebar(session, selectedSessionID: selectedSessionID)
                && !assistantShouldHideShadowProviderSession(
                    session,
                    selectedSessionID: selectedSessionID,
                    canonicalThreadID: canonicalThreadID(forProviderSessionID: session.id)
                )
        }
    }

    var visibleArchivedSidebarSessions: [AssistantSessionSummary] {
        projectFilteredSidebarSessions.filter { session in
            session.isArchived
                && assistantShouldListSessionInSidebar(session, selectedSessionID: selectedSessionID)
                && !assistantShouldHideShadowProviderSession(
                    session,
                    selectedSessionID: selectedSessionID,
                    canonicalThreadID: canonicalThreadID(forProviderSessionID: session.id)
                )
        }
    }
    @Published private(set) var timelineItems: [AssistantTimelineItem] = []
    /// Pre-computed render items, rebuilt only when `timelineItems` changes (not on every @Published update).
    @Published private(set) var cachedRenderItems: [AssistantTimelineRenderItem] = []
    /// Cached set of turn IDs that have plan items, to avoid O(n) scans on every streaming delta.
    private var cachedVisiblePlanTurnIDs: Set<String> = []
    @Published private(set) var transcript: [AssistantTranscriptEntry] = []
    @Published private(set) var planEntries: [AssistantPlanEntry] = []
    @Published private(set) var toolCalls: [AssistantToolCallState] = []
    @Published private(set) var recentToolCalls: [AssistantToolCallState] = []
    @Published private(set) var pendingPermissionRequest: AssistantPermissionRequest?
    @Published private(set) var hudState: AssistantHUDState = .idle
    @Published private(set) var accountSnapshot: AssistantAccountSnapshot = .signedOut
    @Published private(set) var availableModels: [AssistantModelOption] = []
    @Published private(set) var selectedModelID: String?
    @Published private(set) var selectedSubagentModelID: String?
    @Published private(set) var isLoadingModels = false
    @Published var promptDraft = "" {
        didSet {
            if !isRestoringComposerState {
                storeComposerDraft(promptDraft, for: selectedSessionID)
            }
            if promptDraft.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty != nil {
                blockedModeSwitchSuggestion = nil
            }
            refreshModeSwitchSuggestion()
        }
    }
    @Published var selectedSessionID: String? {
        didSet {
            guard oldValue != selectedSessionID else { return }
            clearComposerPlugins()
            restoreComposerState(for: selectedSessionID)
            // Defer heavier state sync to the next run-loop tick so the UI
            // can reflect the session selection change immediately without
            // blocking on execution-state rebuild, skill refresh, and git ops.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.syncSelectedSessionExecutionState()
                self.refreshActiveThreadSkills(syncRuntime: true)
                await self.refreshSelectedCodeTrackingState()
            }
        }
    }
    @Published private(set) var selectedProjectFilter: AssistantProjectFilter?
    @Published var assistantEnabled = false
    @Published var lastStatusMessage: String?
    @Published var showBrowserProfilePicker = false
    @Published private(set) var isTransitioningSession = false
    @Published var sessionInstructions: String = "" {
        didSet {
            syncRuntimeContext()
        }
    }
    @Published private(set) var availableSkills: [AssistantSkillDescriptor] = [] {
        didSet {
            refreshActiveThreadSkills(syncRuntime: true)
        }
    }
    @Published private(set) var activeThreadSkills: [AssistantThreadSkillState] = []
    @Published private(set) var codexPlugins: [AssistantCodexPluginSummary] = []
    @Published private(set) var codexPluginDetailsByID: [String: AssistantCodexPluginDetail] = [:]
    @Published private(set) var codexPluginAppStatuses: [AssistantCodexPluginAppStatus] = []
    @Published private(set) var codexPluginMCPServerStatuses: [AssistantCodexPluginMCPServerStatus] = []
    @Published private(set) var isRefreshingCodexPlugins = false
    @Published private(set) var codexPluginErrorMessage: String?
    @Published private(set) var codexPluginOperationIDs: Set<String> = []
    @Published var selectedComposerPlugins: [AssistantComposerPluginSelection] = []
    @Published private(set) var selectedComposerPluginOwnerSessionID: String?
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
    @Published var taskMode: AssistantTaskMode = .chat {
        didSet {
            guard oldValue != taskMode else { return }
            guard !isRestoringSessionConfiguration else { return }
            syncRuntimeContext()
        }
    }
    @Published private(set) var proposedPlan: String?
    @Published var attachments: [AssistantAttachment] = [] {
        didSet {
            guard !isRestoringComposerState else { return }
            storeAttachments(attachments, for: selectedSessionID)
        }
    }
    @Published private(set) var modeSwitchSuggestion: AssistantModeSwitchSuggestion?
    @Published private(set) var currentMemoryFileURL: URL?
    @Published private(set) var memoryStatusMessage: String?
    @Published private(set) var pendingMemorySuggestions: [AssistantMemorySuggestion] = []
    @Published private(set) var historyBranchState: AssistantHistoryBranchState?
    @Published private(set) var isRestoringHistoryBranch: Bool = false
    @Published private(set) var historyActionsRevision: Int = 0
    @Published private(set) var selectedCodeTrackingState: AssistantCodeTrackingState?
    @Published private(set) var selectedCodeReviewPanelState: AssistantCodeReviewPanelState?
    @Published private(set) var memoryInspectorSnapshot: AssistantMemoryInspectorSnapshot?
    @Published private(set) var lastAssistantNotesMutation: AssistantNotesMutationEvent?
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
    private let runtimeFactory: () -> CodexAssistantRuntime
    private let rootRuntime: CodexAssistantRuntime
    private let codexTranscriptionRuntime: CodexAssistantRuntime
    private let settings: SettingsStore
    private let memoryStore: MemorySQLiteStore
    private let projectStore: AssistantProjectStore
    private let temporarySessionStore: AssistantTemporarySessionStore
    private let sessionRegistry: AssistantSessionRegistry
    private let threadSkillStore: AssistantThreadSkillStore
    private let skillScanService: AssistantSkillScanService
    private let skillImportService: AssistantSkillImportService
    private let skillWizardService: AssistantSkillWizardService
    private let projectMemoryService: AssistantProjectMemoryService
    private let threadMemoryService: AssistantThreadMemoryService
    private let memoryRetrievalService: AssistantMemoryRetrievalService
    private let memorySuggestionService: AssistantMemorySuggestionService
    private let memoryInspectorService: AssistantMemoryInspectorService
    private let automationMemoryService: AutomationMemoryService
    private let completionNotificationService: AssistantCompletionNotificationService
    private let conversationStore: AssistantConversationStore
    private let assistantNotesToolService: AssistantNotesToolService
    private let threadRewriteService: CodexThreadRewriteService
    private let gitCheckpointService: GitCheckpointService
    private let conversationCheckpointStore: AssistantConversationCheckpointStore
    private let assistantSpeechPlaybackService: AssistantSpeechPlaybackService
    private let assistantLegacyTADACleanupSupport: AssistantLegacyTADACleanupSupport
    private let humeVoiceCatalogService: HumeVoiceCatalogService
    private let humeConversationService: HumeConversationService
    private var lastSubmittedPrompt: String?
    private var transcriptSessionID: String?
    private var timelineSessionID: String?
    private var transcriptEntriesBySessionID: [String: [AssistantTranscriptEntry]] = [:]
    private var timelineItemsBySessionID: [String: [AssistantTimelineItem]] = [:]
    private var providerRuntimeSurfaceByThreadID: [String: [AssistantRuntimeBackend: AssistantProviderRuntimeSurfaceSnapshot]] = [:]
    private var providerAvailableModelsByBackend: [AssistantRuntimeBackend: [AssistantModelOption]] = [:]
    private var requestedTimelineHistoryLimitBySessionID: [String: Int] = [:]
    private var requestedTranscriptHistoryLimitBySessionID: [String: Int] = [:]
    private var canLoadMoreHistoryBySessionID: [String: Bool] = [:]
    private var editableTurnsBySessionID: [String: [CodexEditableTurn]] = [:]
    private var sessionLoadRequestID = UUID()
    private var deferredSessionHistoryReloadTask: Task<Void, Never>?
    private var selectedSessionWarmupTask: Task<Void, Never>?
    private var isSendingPrompt = false
    private var isRefreshingEnvironment = false
    private var pendingEnvironmentRefreshPermissions: AssistantPermissionSnapshot?
    private var isRefreshingSessions = false
    private var isRestoringSessionConfiguration = false
    private var oneShotSessionInstructions: String?
    private var notesWorkspaceRuntimeContext: AssistantNotesRuntimeContext?
    private var blockedModeSwitchSuggestion: AssistantModeSwitchSuggestion?
    private var proposedPlanSessionID: String?
    private var composerDraftBySessionID: [String: String] = [:]
    private var attachmentsBySessionID: [String: [AssistantAttachment]] = [:]
    private var sessionExecutionStateBySessionID: [String: AssistantSessionExecutionState] = [:]
    private var sessionRuntimesBySessionID: [String: CodexAssistantRuntime] = [:]
    private var codexPluginUtilityRuntime: CodexAssistantRuntime?
    private var codexPluginLastRefreshAt: Date?
    private var pendingCodexPluginCatalogRefreshForceRemoteSync: Bool?
    private var isRestoringComposerState = false
    private var memoryScopeBySessionID: [String: MemoryScopeContext] = [:]
    private var pendingResumeContextSessionIDs: Set<String> = []
    private var pendingResumeContextSnapshotsBySessionID: [String: String] = [:]
    private var pendingResumeContextMetadataBySessionID: [String: [String: String]] = [:]
    private var pendingFreshSessionIDs: Set<String> = []
    private var pendingFreshSessionSourcesByID: [String: AssistantSessionSource] = [:]
    private var temporarySessionIDs: Set<String> = []
    private var deletedSessionIDs: Set<String> = []
    private var lastSubmittedAttachments: [AssistantAttachment] = []
    private var lastSpokenAssistantTimelineItemID: String?
    private var lastSpokenAssistantTurnID: String?
    private var pendingTimelineCacheSaveWorkItems: [String: DispatchWorkItem] = [:]
    private var pendingConversationSnapshotSaveWorkItems: [String: DispatchWorkItem] = [:]
    private var dirtyConversationSnapshotSessionIDs: Set<String> = []
    private var isRefreshingProjectMemory = false
    private var projectMemoryCatchUpTask: Task<Void, Never>?
    private var activeMemoryInspectorTarget: AssistantMemoryInspectorTarget?
    private var didPurgeTemporarySessionsOnStartup = false
    private var codeTrackingStateBySessionID: [String: AssistantCodeTrackingState] = [:]
    private var pendingCodeCheckpointBaselinesBySessionID: [String: AssistantPendingCodeCheckpointBaseline] = [:]
    private var pendingCodeCheckpointStartTasksBySessionID: [String: Task<Void, Never>] = [:]
    private var pendingCodeCheckpointRecoveryRetryTasksBySessionID: [String: Task<Void, Never>] = [:]
    private var sessionCatalogCWDCacheBySessionID: [String: SessionCatalogCWDCacheEntry] = [:]
    private var idleCodeCheckpointRecoveryAttemptedSessionIDs: Set<String> = []
    private var pendingConversationCheckpointCaptureTasksByKey: [String: Task<Void, Never>] = [:]
    private var visibleProviderSurfaceBackend: AssistantRuntimeBackend?
    var onStartLiveVoiceSession: ((AssistantLiveVoiceSessionSurface) -> Void)?
    var onEndLiveVoiceSession: (() -> Void)?
    var onStopLiveVoiceSpeaking: (() -> Void)?
    var onTurnCompletion: ((AssistantTurnCompletionStatus) -> Void)?

    var runtime: CodexAssistantRuntime {
        runtime(for: selectedSessionID) ?? rootRuntime
    }

    func resolveCodexTranscriptionAuthContext(refreshToken: Bool = true) async throws -> CodexTranscriptionAuthContext {
        let guidance = await installSupport.inspect(backend: .codex)
        codexTranscriptionRuntime.backend = .codex
        _ = try await codexTranscriptionRuntime.refreshEnvironment(codexPath: guidance.codexPath)
        return try await codexTranscriptionRuntime.resolveTranscriptionAuthContext(refreshToken: refreshToken)
    }

    private init(
        installSupport: CodexInstallSupport = CodexInstallSupport(),
        sessionCatalog: CodexSessionCatalog = CodexSessionCatalog(),
        runtime: CodexAssistantRuntime? = nil,
        settings: SettingsStore? = nil,
        memoryStore: MemorySQLiteStore? = nil,
        projectStore: AssistantProjectStore? = nil,
        temporarySessionStore: AssistantTemporarySessionStore? = nil,
        sessionRegistry: AssistantSessionRegistry? = nil,
        threadSkillStore: AssistantThreadSkillStore? = nil,
        skillScanService: AssistantSkillScanService? = nil,
        skillImportService: AssistantSkillImportService? = nil,
        skillWizardService: AssistantSkillWizardService? = nil,
        threadMemoryService: AssistantThreadMemoryService? = nil,
        memoryRetrievalService: AssistantMemoryRetrievalService? = nil,
        memorySuggestionService: AssistantMemorySuggestionService? = nil,
        conversationStore: AssistantConversationStore? = nil,
        threadRewriteService: CodexThreadRewriteService? = nil,
        automationMemoryService: AutomationMemoryService = .shared,
        completionNotificationService: AssistantCompletionNotificationService? = nil,
        assistantSpeechPlaybackService: AssistantSpeechPlaybackService? = nil,
        assistantLegacyTADACleanupSupport: AssistantLegacyTADACleanupSupport = AssistantLegacyTADACleanupSupport()
    ) {
        self.installSupport = installSupport
        self.sessionCatalog = sessionCatalog
        let resolvedSettings = settings ?? .shared
        let initialPreferredModelID = Self.normalizedStartupPreferredModelID(
            for: resolvedSettings.assistantBackend,
            storedModelID: resolvedSettings.assistantPreferredModelID.nonEmpty
        )
        if resolvedSettings.assistantPreferredModelID.nonEmpty != initialPreferredModelID {
            resolvedSettings.assistantPreferredModelID = initialPreferredModelID ?? ""
        }
        self.settings = resolvedSettings
        self.installGuidance = .placeholder(for: resolvedSettings.assistantBackend)
        self.selectedModelID = initialPreferredModelID
        self.selectedSubagentModelID = resolvedSettings.assistantPreferredSubagentModelID.nonEmpty
        let resolvedProjectStore = projectStore ?? AssistantProjectStore()
        let resolvedConversationStore = conversationStore ?? AssistantConversationStore()
        let resolvedAssistantNotesToolService = AssistantNotesToolService(
            projectStore: resolvedProjectStore,
            conversationStore: resolvedConversationStore
        )
        let initialRuntime = runtime ?? CodexAssistantRuntime(
            preferredModelID: initialPreferredModelID,
            preferredSubagentModelID: resolvedSettings.assistantPreferredSubagentModelID.nonEmpty,
            assistantNotesService: resolvedAssistantNotesToolService
        )
        initialRuntime.backend = resolvedSettings.assistantBackend
        self.rootRuntime = initialRuntime
        let transcriptionRuntime = CodexAssistantRuntime()
        transcriptionRuntime.backend = .codex
        self.codexTranscriptionRuntime = transcriptionRuntime
        self.runtimeFactory = { [settings = resolvedSettings, assistantNotesToolService = resolvedAssistantNotesToolService] in
            let preferredModelID = Self.normalizedStartupPreferredModelID(
                for: settings.assistantBackend,
                storedModelID: settings.assistantPreferredModelID.nonEmpty
            )
            let runtime = CodexAssistantRuntime(
                preferredModelID: preferredModelID,
                preferredSubagentModelID: settings.assistantPreferredSubagentModelID.nonEmpty,
                assistantNotesService: assistantNotesToolService
            )
            runtime.backend = settings.assistantBackend
            return runtime
        }
        let resolvedMemoryStore = memoryStore ?? (try? MemorySQLiteStore()) ?? MemorySQLiteStore.fallback()
        self.memoryStore = resolvedMemoryStore
        self.projectStore = resolvedProjectStore
        self.temporarySessionStore = temporarySessionStore ?? AssistantTemporarySessionStore()
        self.sessionRegistry = sessionRegistry ?? AssistantSessionRegistry()
        let resolvedSkillScanService = skillScanService ?? AssistantSkillScanService()
        self.skillScanService = resolvedSkillScanService
        self.threadSkillStore = threadSkillStore ?? AssistantThreadSkillStore()
        self.skillImportService = skillImportService ?? AssistantSkillImportService(
            scanService: resolvedSkillScanService
        )
        self.skillWizardService = skillWizardService ?? AssistantSkillWizardService(
            scanService: resolvedSkillScanService
        )
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
        self.conversationStore = resolvedConversationStore
        self.assistantNotesToolService = resolvedAssistantNotesToolService
        self.gitCheckpointService = GitCheckpointService()
        self.conversationCheckpointStore = AssistantConversationCheckpointStore(
            sessionCatalog: self.sessionCatalog,
            conversationStore: self.conversationStore,
            threadMemoryService: resolvedThreadMemoryService,
            memorySuggestionService: self.memorySuggestionService,
            memoryStore: resolvedMemoryStore
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
        self.completionNotificationService = completionNotificationService ?? AssistantCompletionNotificationService()
        self.threadRewriteService = threadRewriteService ?? CodexThreadRewriteService(
            sessionCatalog: self.sessionCatalog,
            conversationStore: self.conversationStore
        )
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
        resolvedAssistantNotesToolService.setSessionSummaryProvider { [weak self] sessionID in
            self?.sessions.first {
                $0.id.caseInsensitiveCompare(sessionID) == .orderedSame
            }
        }
        resolvedAssistantNotesToolService.setMutationHandler { [weak self] event in
            self?.lastAssistantNotesMutation = event
        }
        bindRuntimeCallbacks(initialRuntime, preferredSessionID: nil)
        self.assistantSpeechPlaybackService.onPlaybackStateChange = { [weak self] isPlaying in
            Task { @MainActor in
                self?.assistantVoicePlaybackActive = isPlaying
            }
        }
        reloadProjectsFromStore()
        reloadTemporarySessionsFromStore()
        refreshSkills()
        refreshModeSwitchSuggestion()
    }

    private func runtime(for sessionID: String?) -> CodexAssistantRuntime? {
        guard let normalizedSessionID = normalizedSessionID(sessionID) else { return nil }
        return sessionRuntimesBySessionID[normalizedSessionID]
    }

    private func ensureRuntime(
        for sessionID: String?,
        createIfNeeded: Bool = true
    ) -> CodexAssistantRuntime {
        if let existing = runtime(for: sessionID) {
            return existing
        }

        guard createIfNeeded,
              let normalizedSessionID = normalizedSessionID(sessionID) else {
            return rootRuntime
        }

        let runtime = runtimeFactory()
        sessionRuntimesBySessionID[normalizedSessionID] = runtime
        bindRuntimeCallbacks(runtime, preferredSessionID: sessionID)
        if sessionsMatch(normalizedSessionID, selectedSessionID) {
            applyCurrentRuntimeContext(to: runtime, threadID: normalizedSessionID)
        }
        return runtime
    }

    private func makeUnboundRuntime() -> CodexAssistantRuntime {
        if sessionIDBoundToRuntime(rootRuntime) == nil,
           rootRuntime.currentSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty == nil,
           !rootRuntime.hasActiveTurn {
            return rootRuntime
        }

        let runtime = runtimeFactory()
        bindRuntimeCallbacks(runtime, preferredSessionID: nil)
        return runtime
    }

    var canUseCodexPlugins: Bool {
        visibleAssistantBackend == .codex
    }

    var installedCodexPluginSelections: [AssistantComposerPluginSelection] {
        codexPlugins
            .filter(\.isInstalled)
            .map { plugin in
                AssistantComposerPluginSelection(
                    pluginID: plugin.id,
                    displayName: plugin.displayName,
                    summary: plugin.summary,
                    needsSetup: codexPluginReadiness(for: plugin).state == .needsSetup,
                    iconPath: plugin.iconPath,
                    iconRootPath: plugin.source,
                    iconDataURL: nil
                )
            }
            .sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
    }

    func refreshCodexPluginCatalogIfNeeded() async {
        guard canUseCodexPlugins else { return }
        if codexPlugins.isEmpty {
            await refreshCodexPluginCatalog(forceRemoteSync: true)
            return
        }
        if let lastRefresh = codexPluginLastRefreshAt,
           Date().timeIntervalSince(lastRefresh) < 120 {
            return
        }
        await refreshCodexPluginCatalog(forceRemoteSync: false)
    }

    func refreshCodexPluginCatalog(forceRemoteSync: Bool) async {
        guard canUseCodexPlugins else {
            codexPluginErrorMessage = nil
            return
        }
        if isRefreshingCodexPlugins {
            pendingCodexPluginCatalogRefreshForceRemoteSync =
                (pendingCodexPluginCatalogRefreshForceRemoteSync ?? false) || forceRemoteSync
            CrashReporter.logInfo(
                "Assistant plugin catalog refresh queued forceRemoteSync=\(forceRemoteSync) pendingForceRemoteSync=\(pendingCodexPluginCatalogRefreshForceRemoteSync ?? false)"
            )
            return
        }

        CrashReporter.logInfo(
            "Assistant plugin catalog refresh started forceRemoteSync=\(forceRemoteSync) existingCatalogCount=\(codexPlugins.count)"
        )
        isRefreshingCodexPlugins = true
        defer {
            isRefreshingCodexPlugins = false
            let queuedForceRemoteSync = pendingCodexPluginCatalogRefreshForceRemoteSync
            pendingCodexPluginCatalogRefreshForceRemoteSync = nil
            CrashReporter.logInfo(
                "Assistant plugin catalog refresh finished finalCatalogCount=\(codexPlugins.count) queuedForceRemoteSync=\(queuedForceRemoteSync.map(String.init(describing:)) ?? "nil")"
            )
            if let queuedForceRemoteSync {
                Task { [weak self] in
                    await self?.refreshCodexPluginCatalog(forceRemoteSync: queuedForceRemoteSync)
                }
            }
        }

        let hadExistingCatalog = !codexPlugins.isEmpty

        if forceRemoteSync && !hadExistingCatalog {
            do {
                CrashReporter.logInfo("Assistant plugin catalog bootstrap fetch starting")
                let bootstrapSummaries = try await fetchCodexPluginSummaries(mode: .localBootstrap)
                if !bootstrapSummaries.isEmpty {
                    let warnings = await applyCodexPluginCatalog(bootstrapSummaries)
                    codexPluginErrorMessage = warnings.joined(separator: "\n").nonEmpty
                    lastStatusMessage = nil
                    CrashReporter.logInfo(
                        "Assistant plugin catalog bootstrap applied count=\(bootstrapSummaries.count) warnings=\(warnings.count)"
                    )
                }
            } catch {
                CrashReporter.logWarning(
                    "Assistant plugin catalog local bootstrap failed: \(error.localizedDescription)"
                )
            }
        }

        do {
            CrashReporter.logInfo(
                "Assistant plugin catalog standard fetch starting forceRemoteSync=\(forceRemoteSync)"
            )
            let summaries = try await fetchCodexPluginSummaries(
                mode: .standard(forceRemoteSync: forceRemoteSync)
            )
            guard !summaries.isEmpty else {
                let emptyCatalogMessage = "Codex returned an empty plugin catalog."
                if codexPlugins.isEmpty {
                    codexPluginDetailsByID = [:]
                    codexPluginAppStatuses = []
                    codexPluginMCPServerStatuses = []
                    codexPluginErrorMessage = "OpenAssist couldn't load the Codex plugin catalog."
                } else {
                    codexPluginErrorMessage = """
                    Showing the last loaded plugin list.
                    Codex couldn't finish syncing plugins.
                    """
                }
                lastStatusMessage = emptyCatalogMessage
                CrashReporter.logWarning(
                    "Assistant plugin catalog standard fetch returned empty existingCatalogCount=\(codexPlugins.count)"
                )
                return
            }
            let warnings = await applyCodexPluginCatalog(summaries)
            codexPluginErrorMessage = warnings.joined(separator: "\n").nonEmpty
            lastStatusMessage = nil
            CrashReporter.logInfo(
                "Assistant plugin catalog standard fetch applied count=\(summaries.count) warnings=\(warnings.count)"
            )
        } catch {
            lastStatusMessage = error.localizedDescription
            if codexPlugins.isEmpty {
                codexPluginDetailsByID = [:]
                codexPluginAppStatuses = []
                codexPluginMCPServerStatuses = []
                codexPluginErrorMessage = "OpenAssist couldn't load the Codex plugin catalog."
            } else {
                codexPluginErrorMessage = """
                Showing the last loaded plugin list.
                Codex couldn't finish syncing plugins.
                """
            }
            CrashReporter.logWarning(
                "Assistant plugin catalog refresh failed existingCatalogCount=\(codexPlugins.count) message=\(error.localizedDescription)"
            )
        }
    }

    private func fetchCodexPluginSummaries(
        mode: CodexPluginCatalogFetchMode
    ) async throws -> [AssistantCodexPluginSummary] {
        let attempts: [(label: String, restartRuntime: Bool, forceRemoteSync: Bool, cwds: [String])]
        switch mode {
        case .localBootstrap:
            attempts = [
                (
                    label: "local-bootstrap",
                    restartRuntime: false,
                    forceRemoteSync: false,
                    cwds: []
                ),
                (
                    label: "local-bootstrap-fresh-runtime",
                    restartRuntime: true,
                    forceRemoteSync: false,
                    cwds: []
                ),
            ]
        case .standard(let forceRemoteSync):
            let preferredCWDs = codexPluginCatalogCWDs()
            var nextAttempts: [(label: String, restartRuntime: Bool, forceRemoteSync: Bool, cwds: [String])] = [
                (
                    label: "initial",
                    restartRuntime: false,
                    forceRemoteSync: forceRemoteSync,
                    cwds: preferredCWDs
                ),
                (
                    label: "fresh-runtime",
                    restartRuntime: true,
                    forceRemoteSync: true,
                    cwds: preferredCWDs
                ),
            ]
            if !preferredCWDs.isEmpty {
                nextAttempts.append(
                    (
                        label: "fresh-runtime-no-cwds",
                        restartRuntime: true,
                        forceRemoteSync: true,
                        cwds: []
                    )
                )
            }
            attempts = nextAttempts
        }

        var lastError: Error?

        for attempt in attempts {
            if attempt.restartRuntime {
                CrashReporter.logInfo(
                    "Assistant plugin catalog resetting utility runtime before \(attempt.label)"
                )
                await resetCodexPluginUtilityRuntime()
            }

            do {
                CrashReporter.logInfo(
                    "Assistant plugin catalog fetch attempt=\(attempt.label) cwds=\(attempt.cwds.count) forceRemoteSync=\(attempt.forceRemoteSync)"
                )
                let summaries = try await ensureCodexPluginUtilityRuntime().listPlugins(
                    cwds: attempt.cwds,
                    forceRemoteSync: attempt.forceRemoteSync
                )
                if !summaries.isEmpty {
                    if attempt.label != "initial" {
                        CrashReporter.logInfo(
                            "Assistant plugin catalog recovered via \(attempt.label) count=\(summaries.count)"
                        )
                    }
                    return summaries
                }

                CrashReporter.logWarning(
                    "Assistant plugin catalog returned empty via \(attempt.label) cwds=\(attempt.cwds.count) forceRemoteSync=\(attempt.forceRemoteSync)"
                )
            } catch {
                lastError = error
                CrashReporter.logWarning(
                    "Assistant plugin catalog failed via \(attempt.label): \(error.localizedDescription)"
                )
            }
        }

        if let lastError {
            throw lastError
        }
        return []
    }

    private func applyCodexPluginCatalog(
        _ summaries: [AssistantCodexPluginSummary]
    ) async -> [String] {
        let runtime = ensureCodexPluginUtilityRuntime()
        let installedPluginIDs = Set(
            summaries.filter(\.isInstalled).map { $0.id.lowercased() }
        )
        CrashReporter.logInfo(
            "Assistant plugin catalog apply started summaryCount=\(summaries.count) installedCount=\(installedPluginIDs.count) cachedDetailCount=\(codexPluginDetailsByID.count)"
        )

        var nextDetails = codexPluginDetailsByID
        nextDetails = nextDetails.filter { key, _ in
            installedPluginIDs.contains(key.lowercased())
        }

        codexPlugins = summaries
        codexPluginLastRefreshAt = Date()
        pruneSelectedComposerPlugins()

        var warnings: [String] = []

        do {
            codexPluginAppStatuses = try await runtime.listPluginApps()
        } catch {
            warnings.append("Couldn't load plugin app setup state.")
            lastStatusMessage = error.localizedDescription
        }

        do {
            codexPluginMCPServerStatuses = try await runtime.listPluginMCPServerStatuses()
        } catch {
            warnings.append("Couldn't load plugin MCP setup state.")
            lastStatusMessage = error.localizedDescription
        }

        for plugin in summaries where plugin.isInstalled {
            if nextDetails[plugin.id] == nil {
                if let detail = try? await runtime.readPlugin(
                    marketplacePath: plugin.marketplacePath,
                    pluginName: plugin.pluginName
                ) {
                    nextDetails[plugin.id] = detail
                }
            }
        }

        codexPluginDetailsByID = nextDetails
        CrashReporter.logInfo(
            "Assistant plugin catalog apply finished detailCount=\(codexPluginDetailsByID.count) appStatusCount=\(codexPluginAppStatuses.count) mcpStatusCount=\(codexPluginMCPServerStatuses.count) warnings=\(warnings.count)"
        )
        return warnings
    }

    private enum CodexPluginCatalogFetchMode {
        case localBootstrap
        case standard(forceRemoteSync: Bool)
    }

    func loadCodexPluginDetail(pluginID: String) async {
        guard let summary = codexPluginSummary(for: pluginID) else { return }
        if codexPluginDetailsByID[summary.id] != nil {
            return
        }

        do {
            let detail = try await ensureCodexPluginUtilityRuntime().readPlugin(
                marketplacePath: summary.marketplacePath,
                pluginName: summary.pluginName
            )
            codexPluginDetailsByID[summary.id] = detail
        } catch {
            codexPluginErrorMessage = error.localizedDescription
        }
    }

    func installCodexPlugin(pluginID: String) async {
        guard let summary = codexPluginSummary(for: pluginID) else { return }
        guard !codexPluginOperationIDs.contains(summary.id) else { return }

        codexPluginOperationIDs.insert(summary.id)
        defer { codexPluginOperationIDs.remove(summary.id) }

        do {
            let runtime = ensureCodexPluginUtilityRuntime()
            try await runtime.installPlugin(
                marketplacePath: summary.marketplacePath,
                pluginName: summary.pluginName,
                forceRemoteSync: true
            )
            try? await runtime.reloadMCPServerConfiguration()
            lastStatusMessage = "Installed \(summary.displayName)."
            await refreshCodexPluginCatalog(forceRemoteSync: true)
        } catch {
            codexPluginErrorMessage = error.localizedDescription
            lastStatusMessage = error.localizedDescription
        }
    }

    func uninstallCodexPlugin(pluginID: String) async {
        guard let summary = codexPluginSummary(for: pluginID) else { return }
        guard !codexPluginOperationIDs.contains(summary.id) else { return }

        codexPluginOperationIDs.insert(summary.id)
        defer { codexPluginOperationIDs.remove(summary.id) }

        do {
            let runtime = ensureCodexPluginUtilityRuntime()
            try await runtime.uninstallPlugin(
                pluginID: summary.id,
                forceRemoteSync: true
            )
            try? await runtime.reloadMCPServerConfiguration()
            selectedComposerPlugins.removeAll { $0.pluginID.caseInsensitiveCompare(summary.id) == .orderedSame }
            if selectedComposerPlugins.isEmpty {
                selectedComposerPluginOwnerSessionID = nil
            }
            lastStatusMessage = "Uninstalled \(summary.displayName)."
            await refreshCodexPluginCatalog(forceRemoteSync: true)
        } catch {
            codexPluginErrorMessage = error.localizedDescription
            lastStatusMessage = error.localizedDescription
        }
    }

    func startCodexPluginMCPAuth(serverName: String) async {
        guard let normalizedServerName = serverName.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return
        }

        do {
            let url = try await ensureCodexPluginUtilityRuntime().beginMCPServerOAuthLogin(
                serverName: normalizedServerName
            )
            if let url {
                NSWorkspace.shared.open(url)
            }
            lastStatusMessage = "Started sign-in for \(normalizedServerName)."
        } catch {
            codexPluginErrorMessage = error.localizedDescription
            lastStatusMessage = error.localizedDescription
        }
    }

    func selectComposerPlugin(pluginID: String) {
        guard let ownerSessionID = selectedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            lastStatusMessage = "Open the chat you want to use first, then attach the plugin."
            return
        }
        guard let summary = codexPluginSummary(for: pluginID), summary.isInstalled else {
            return
        }
        let selection = AssistantComposerPluginSelection(
            pluginID: summary.id,
            displayName: summary.displayName,
            summary: summary.summary,
            needsSetup: codexPluginReadiness(for: summary).state == .needsSetup,
            iconPath: summary.iconPath,
            iconRootPath: summary.source
        )
        if let currentOwner = selectedComposerPluginOwnerSessionID?.nonEmpty,
           !sessionsMatch(currentOwner, ownerSessionID) {
            selectedComposerPlugins = []
        }
        selectedComposerPluginOwnerSessionID = ownerSessionID
        guard !selectedComposerPlugins.contains(where: {
            $0.pluginID.caseInsensitiveCompare(selection.pluginID) == .orderedSame
        }) else {
            return
        }
        selectedComposerPlugins.append(selection)
        selectedComposerPlugins.sort {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    func removeComposerPlugin(pluginID: String) {
        selectedComposerPlugins.removeAll {
            $0.pluginID.caseInsensitiveCompare(pluginID) == .orderedSame
        }
        if selectedComposerPlugins.isEmpty {
            selectedComposerPluginOwnerSessionID = nil
        }
    }

    func clearComposerPlugins() {
        selectedComposerPlugins = []
        selectedComposerPluginOwnerSessionID = nil
    }

    var visibleSelectedComposerPlugins: [AssistantComposerPluginSelection] {
        guard let ownerSessionID = selectedComposerPluginOwnerSessionID?.nonEmpty,
              let currentSessionID = selectedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
              sessionsMatch(ownerSessionID, currentSessionID) else {
            return []
        }
        return selectedComposerPlugins
    }

    func codexPluginDetail(for pluginID: String) -> AssistantCodexPluginDetail? {
        guard let normalizedID = normalizedCodexPluginID(pluginID) else { return nil }
        return codexPluginDetailsByID.first {
            $0.key.caseInsensitiveCompare(normalizedID) == .orderedSame
        }?.value
    }

    func codexPluginReadiness(for plugin: AssistantCodexPluginSummary) -> AssistantCodexPluginReadiness {
        guard plugin.isInstalled else {
            return AssistantCodexPluginReadiness(
                state: .available,
                appStatuses: [],
                mcpStatuses: []
            )
        }

        let detail = codexPluginDetail(for: plugin.id)
        let appStatuses = (detail?.apps ?? []).compactMap { app in
            codexPluginAppStatus(for: app, plugin: plugin)
        }
        let mcpStatuses = (detail?.mcpServers ?? []).compactMap { server in
            codexPluginMCPServerStatuses.first {
                $0.name.caseInsensitiveCompare(server.name) == .orderedSame
            }
        }
        let needsSetup = appStatuses.contains(where: \.needsSetup)
            || mcpStatuses.contains(where: \.needsSetup)
        return AssistantCodexPluginReadiness(
            state: needsSetup ? .needsSetup : .ready,
            appStatuses: appStatuses,
            mcpStatuses: mcpStatuses
        )
    }

    private func ensureCodexPluginUtilityRuntime() -> CodexAssistantRuntime {
        if let codexPluginUtilityRuntime {
            return codexPluginUtilityRuntime
        }

        let runtime = runtimeFactory()
        runtime.backend = .codex
        runtime.onHealthUpdate = nil
        runtime.onTranscript = nil
        runtime.onTranscriptMutation = nil
        runtime.onTimelineMutation = nil
        runtime.onActivityItemUpdate = nil
        runtime.onHUDUpdate = nil
        runtime.onPlanUpdate = nil
        runtime.onToolCallUpdate = nil
        runtime.onPermissionRequest = nil
        runtime.onSessionChange = nil
        runtime.onStatusMessage = nil
        runtime.onTokenUsageUpdate = nil
        runtime.onSubagentUpdate = nil
        runtime.onProposedPlan = nil
        runtime.onModeRestriction = nil
        runtime.onTurnCompletion = nil
        runtime.onTitleRequest = nil
        codexPluginUtilityRuntime = runtime
        return runtime
    }

    private func resetCodexPluginUtilityRuntime() async {
        guard let codexPluginUtilityRuntime else { return }
        await codexPluginUtilityRuntime.stop()
        self.codexPluginUtilityRuntime = nil
    }

    private func pruneSelectedComposerPlugins() {
        let installedIDs = Set(codexPlugins.filter(\.isInstalled).map { $0.id.lowercased() })
        selectedComposerPlugins.removeAll { selection in
            !installedIDs.contains(selection.pluginID.lowercased())
        }
    }

    private func codexPluginCatalogCWDs() -> [String] {
        var values: [String] = []
        var seen = Set<String>()

        func append(path: String?) {
            guard let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
                return
            }
            let normalized = trimmed.lowercased()
            guard seen.insert(normalized).inserted else { return }
            values.append(trimmed)
        }

        append(path: selectedSessionID.flatMap { resolvedSessionCWD(for: $0) })
        for project in visibleLeafProjects {
            append(path: project.linkedFolderPath)
        }
        return values
    }

    private func normalizedCodexPluginID(_ pluginID: String?) -> String? {
        pluginID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    private func codexPluginSummary(for pluginID: String) -> AssistantCodexPluginSummary? {
        guard let normalizedID = normalizedCodexPluginID(pluginID) else { return nil }
        return codexPlugins.first {
            $0.id.caseInsensitiveCompare(normalizedID) == .orderedSame
        }
    }

    private func codexPluginAppStatus(
        for app: AssistantCodexPluginApp,
        plugin: AssistantCodexPluginSummary
    ) -> AssistantCodexPluginAppStatus? {
        codexPluginAppStatuses.first { status in
            if status.id.caseInsensitiveCompare(app.id) == .orderedSame {
                return true
            }
            if status.name.caseInsensitiveCompare(app.name) == .orderedSame {
                return true
            }
            return status.pluginDisplayNames.contains {
                $0.caseInsensitiveCompare(plugin.displayName) == .orderedSame
            }
        }
    }

    private func uniqueCodexPluginIDs(_ pluginIDs: [String]) -> [String] {
        var seen = Set<String>()
        return pluginIDs.compactMap { rawID in
            guard let normalizedID = normalizedCodexPluginID(rawID) else { return nil }
            let lowered = normalizedID.lowercased()
            guard seen.insert(lowered).inserted else { return nil }
            return normalizedID
        }
    }

    private func resolvedComposerPluginSelections(
        for pluginIDs: [String],
        prompt: String? = nil
    ) -> [AssistantComposerPluginSelection] {
        uniqueCodexPluginIDs(pluginIDs).compactMap { pluginID in
            if let selection = installedCodexPluginSelections.first(where: {
                $0.pluginID.caseInsensitiveCompare(pluginID) == .orderedSame
            }) {
                if let summary = codexPluginSummary(for: selection.pluginID) {
                    return AssistantComposerPluginSelection(
                        pluginID: selection.pluginID,
                        displayName: composerPluginSelectionDisplayName(
                            for: summary,
                            prompt: prompt
                        ),
                        summary: selection.summary,
                        needsSetup: selection.needsSetup,
                        iconPath: summary.iconPath ?? selection.iconPath,
                        iconRootPath: summary.source ?? selection.iconRootPath
                    )
                }
                return selection
            }
            if let summary = codexPluginSummary(for: pluginID) {
                return AssistantComposerPluginSelection(
                    pluginID: summary.id,
                    displayName: composerPluginSelectionDisplayName(
                        for: summary,
                        prompt: prompt
                    ),
                    summary: summary.summary,
                    needsSetup: codexPluginReadiness(for: summary).state == .needsSetup,
                    iconPath: summary.iconPath,
                    iconRootPath: summary.source
                )
            }

            let pluginName = pluginID.split(separator: "@").first.map(String.init) ?? pluginID
            return AssistantComposerPluginSelection(
                pluginID: pluginID,
                displayName: assistantDisplayPluginName(pluginName: pluginName),
                summary: nil,
                needsSetup: false,
                iconPath: nil,
                iconRootPath: nil
            )
        }
    }

    private func composerPluginSelectionDisplayName(
        for plugin: AssistantCodexPluginSummary,
        prompt: String?
    ) -> String {
        if let matchedApp = matchingComposerPluginAppStatuses(
            for: plugin,
            prompt: prompt
        ).first {
            return matchedApp.name
        }

        if plugin.displayName.caseInsensitiveCompare("Computer Use") == .orderedSame,
           let targetName = inferredComputerUseTargetName(from: prompt) {
            return targetName
        }

        return plugin.displayName
    }

    private func matchingComposerPluginAppStatuses(
        for plugin: AssistantCodexPluginSummary,
        prompt: String?
    ) -> [AssistantCodexPluginAppStatus] {
        guard let prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return []
        }

        let accessibleApps = codexPluginReadiness(for: plugin).appStatuses
            .filter { $0.isAccessible && $0.isEnabled }
        guard !accessibleApps.isEmpty else { return [] }

        let matches = accessibleApps.filter { promptMentionsCodexPluginApp($0, prompt: prompt) }
            .sorted {
                if $0.name.count == $1.name.count {
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                return $0.name.count > $1.name.count
            }
        if !matches.isEmpty {
            return matches
        }

        return accessibleApps.count == 1 ? accessibleApps : []
    }

    private func promptMentionsCodexPluginApp(
        _ appStatus: AssistantCodexPluginAppStatus,
        prompt: String
    ) -> Bool {
        pluginAppMatchCandidates(for: appStatus).contains { candidate in
            promptContainsStandalonePhrase(candidate, within: prompt)
        }
    }

    private func pluginAppMatchCandidates(
        for appStatus: AssistantCodexPluginAppStatus
    ) -> [String] {
        var rawCandidates: [String] = [
            appStatus.name,
            appStatus.id,
            appStatus.id.replacingOccurrences(of: ".", with: " "),
            appStatus.id.replacingOccurrences(of: "-", with: " "),
            appStatus.id.replacingOccurrences(of: "_", with: " "),
        ]

        let vendorPrefixes = ["microsoft ", "google ", "apple "]
        let loweredName = appStatus.name.lowercased()
        for prefix in vendorPrefixes where loweredName.hasPrefix(prefix) {
            let trimmed = String(appStatus.name.dropFirst(prefix.count))
            rawCandidates.append(trimmed)
        }

        var candidates: [String] = []
        var seen = Set<String>()
        for rawCandidate in rawCandidates {
            guard let candidate = rawCandidate.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
                continue
            }
            let lowered = candidate.lowercased()
            guard seen.insert(lowered).inserted else { continue }
            candidates.append(candidate)
        }

        return candidates.sorted {
            if $0.count == $1.count {
                return $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }
            return $0.count > $1.count
        }
    }

    private func promptContainsStandalonePhrase(
        _ phrase: String,
        within prompt: String
    ) -> Bool {
        let trimmedPhrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPhrase.isEmpty else { return false }
        if trimmedPhrase.count < 4 && !trimmedPhrase.contains(" ") {
            return false
        }

        let escaped = NSRegularExpression.escapedPattern(for: trimmedPhrase)
        guard let regex = try? NSRegularExpression(
            pattern: #"(?<![\p{L}\p{N}])\#(escaped)(?![\p{L}\p{N}])"#,
            options: [.caseInsensitive]
        ) else {
            return false
        }
        let fullRange = NSRange(location: 0, length: (prompt as NSString).length)
        return regex.firstMatch(in: prompt, range: fullRange) != nil
    }

    private func inferredComputerUseTargetName(from prompt: String?) -> String? {
        guard let prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return nil
        }

        let candidates = [
            "Brave Browser",
            "Microsoft Teams",
            "Teams",
            "Microsoft Outlook",
            "Outlook",
            "Google Chrome",
            "Chrome",
            "Safari",
            "Messages",
            "System Settings",
            "Finder",
            "Terminal",
            "ChatGPT",
            "Codex",
            "Code - Insiders",
            "Code",
            "Notes",
            "Calendar",
            "Reminders",
            "Preview",
            "Microsoft Word",
            "Word",
            "Microsoft Excel",
            "Excel",
            "WhatsApp",
        ]

        return candidates.first {
            promptContainsStandalonePhrase($0, within: prompt)
        }
    }

    private func resolveCodexPluginPromptState(
        prompt: String,
        selectedPluginIDs: [String],
        backend: AssistantRuntimeBackend
    ) async -> (prompt: String, selectedPluginIDs: [String]) {
        let normalizedIDs = uniqueCodexPluginIDs(selectedPluginIDs)
        guard backend == .codex else {
            return (prompt, normalizedIDs)
        }

        await refreshCodexPluginCatalogIfNeeded()
        let installedPlugins = codexPlugins.filter(\.isInstalled)
        guard !installedPlugins.isEmpty else {
            return (prompt, normalizedIDs)
        }

        let installedPluginsByID = Dictionary(
            uniqueKeysWithValues: installedPlugins.map { ($0.id.lowercased(), $0) }
        )
        var extractedPluginIDs: [String] = []
        var resolvedPrompt = prompt

        resolvedPrompt = replaceExplicitCodexPluginMarkdownLinks(
            in: resolvedPrompt,
            installedPluginsByID: installedPluginsByID,
            extractedPluginIDs: &extractedPluginIDs
        )
        resolvedPrompt = replaceExplicitCodexPluginURLs(
            in: resolvedPrompt,
            installedPluginsByID: installedPluginsByID,
            extractedPluginIDs: &extractedPluginIDs
        )
        extractedPluginIDs.append(
            contentsOf: detectedCodexPluginMentionIDs(
                in: resolvedPrompt,
                installedPlugins: installedPlugins
            )
        )

        return (
            collapsePluginPromptWhitespace(in: resolvedPrompt),
            uniqueCodexPluginIDs(normalizedIDs + extractedPluginIDs)
        )
    }

    private func replaceExplicitCodexPluginMarkdownLinks(
        in prompt: String,
        installedPluginsByID: [String: AssistantCodexPluginSummary],
        extractedPluginIDs: inout [String]
    ) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"\[([^\]]+)\]\(plugin://([^)]+)\)"#,
            options: [.caseInsensitive]
        ) else {
            return prompt
        }

        let nsPrompt = prompt as NSString
        let matches = regex.matches(
            in: prompt,
            range: NSRange(location: 0, length: nsPrompt.length)
        )
        guard !matches.isEmpty else { return prompt }

        let mutable = NSMutableString(string: prompt)
        for match in matches.reversed() {
            guard match.numberOfRanges >= 3 else { continue }
            let rawPluginID = nsPrompt.substring(with: match.range(at: 2))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let plugin = installedPluginsByID[rawPluginID.lowercased()] else { continue }

            let rawLabel = nsPrompt.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let replacement = rawLabel.nonEmpty ?? "@\(plugin.displayName)"
            extractedPluginIDs.append(plugin.id)
            mutable.replaceCharacters(in: match.range, with: replacement)
        }

        return mutable as String
    }

    private func replaceExplicitCodexPluginURLs(
        in prompt: String,
        installedPluginsByID: [String: AssistantCodexPluginSummary],
        extractedPluginIDs: inout [String]
    ) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"plugin://([A-Za-z0-9._-]+@[A-Za-z0-9._-]+)"#,
            options: [.caseInsensitive]
        ) else {
            return prompt
        }

        let nsPrompt = prompt as NSString
        let matches = regex.matches(
            in: prompt,
            range: NSRange(location: 0, length: nsPrompt.length)
        )
        guard !matches.isEmpty else { return prompt }

        let mutable = NSMutableString(string: prompt)
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2 else { continue }
            let rawPluginID = nsPrompt.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let plugin = installedPluginsByID[rawPluginID.lowercased()] else { continue }

            extractedPluginIDs.append(plugin.id)
            mutable.replaceCharacters(in: match.range, with: "@\(plugin.displayName)")
        }

        return mutable as String
    }

    private func detectedCodexPluginMentionIDs(
        in prompt: String,
        installedPlugins: [AssistantCodexPluginSummary]
    ) -> [String] {
        let orderedPlugins = installedPlugins.sorted {
            if $0.displayName.count == $1.displayName.count {
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            return $0.displayName.count > $1.displayName.count
        }

        var detectedIDs: [String] = []
        let fullRange = NSRange(location: 0, length: (prompt as NSString).length)

        for plugin in orderedPlugins {
            let mentionCandidates = [
                plugin.displayName,
                plugin.pluginName,
                plugin.pluginName.replacingOccurrences(of: "-", with: " "),
            ].compactMap {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            }

            for candidate in mentionCandidates {
                let escaped = NSRegularExpression.escapedPattern(for: candidate)
                guard let regex = try? NSRegularExpression(
                    pattern: #"(?<![\p{L}\p{N}_])@\#(escaped)(?=$|[\s\.,!?:;\)\]\}])"#,
                    options: [.caseInsensitive]
                ) else {
                    continue
                }

                if regex.firstMatch(in: prompt, range: fullRange) != nil {
                    detectedIDs.append(plugin.id)
                    break
                }
            }
        }

        return detectedIDs
    }

    private func collapsePluginPromptWhitespace(in prompt: String) -> String {
        var normalized = prompt
        normalized = normalized.replacingOccurrences(
            of: #"[ \t]{2,}"#,
            with: " ",
            options: .regularExpression
        )
        normalized = normalized.replacingOccurrences(
            of: #"\n{3,}"#,
            with: "\n\n",
            options: .regularExpression
        )
        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func codexPluginSelectionContextText(
        for plugins: [AssistantCodexPluginSummary]
    ) -> String? {
        guard !plugins.isEmpty else { return nil }
        let lines = plugins.map { "- \($0.displayName)" }
        return """
        Selected installed plugins for this turn:
        \(lines.joined(separator: "\n"))

        Treat these plugins as the required path for this request.
        Use them first and do not switch to unrelated tools or a generic fallback just because it seems easier.
        If the selected plugins cannot handle the request, say that clearly instead of silently doing the task another way.
        """
    }

    private func codexPluginContextPrefixText(
        selectedPluginIDs: [String],
        backend: AssistantRuntimeBackend
    ) async -> String? {
        guard backend == .codex else { return nil }
        let normalizedIDs = uniqueCodexPluginIDs(selectedPluginIDs)
        guard !normalizedIDs.isEmpty else { return nil }

        await refreshCodexPluginCatalogIfNeeded()
        let summaries = normalizedIDs.compactMap(codexPluginSummary(for:)).filter(\.isInstalled)
        return codexPluginSelectionContextText(for: summaries)
    }

    private func resolvedCodexPluginPromptItems(
        selectedPluginIDs: [String],
        prompt: String,
        backend: AssistantRuntimeBackend
    ) async -> [AssistantCodexPromptInputItem] {
        guard backend == .codex else { return [] }

        let normalizedIDs = uniqueCodexPluginIDs(selectedPluginIDs)
        guard !normalizedIDs.isEmpty else { return [] }

        await refreshCodexPluginCatalogIfNeeded()

        var selectedSummaries: [AssistantCodexPluginSummary] = []
        var items: [AssistantCodexPromptInputItem] = []
        var seenMentionPaths = Set<String>()
        var seenSkillPaths = Set<String>()

        for pluginID in normalizedIDs {
            guard let summary = codexPluginSummary(for: pluginID), summary.isInstalled else {
                continue
            }
            selectedSummaries.append(summary)

            if codexPluginDetail(for: summary.id) == nil {
                await loadCodexPluginDetail(pluginID: summary.id)
            }

            if let detail = codexPluginDetail(for: summary.id) {
                for skill in detail.skills {
                    let trimmedPath = skill.path
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedPath.isEmpty else { continue }
                    guard seenSkillPaths.insert(trimmedPath.lowercased()).inserted else { continue }
                    let skillName = skill.displayName
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .nonEmpty
                        ?? skill.name
                    items.append(.skill(name: skillName, path: trimmedPath))
                }
            }

            let matchedAppStatuses = matchingComposerPluginAppStatuses(
                for: summary,
                prompt: prompt
            )
            for appStatus in matchedAppStatuses {
                let mentionPath = "app://\(appStatus.id)"
                guard seenMentionPaths.insert(mentionPath.lowercased()).inserted else { continue }
                items.append(.mention(name: appStatus.name, path: mentionPath))
            }

            if summary.displayName.caseInsensitiveCompare("Computer Use") == .orderedSame,
               matchedAppStatuses.isEmpty,
               let targetName = inferredComputerUseTargetName(from: prompt) {
                items.append(.text("For Computer Use, focus on \(targetName) on this Mac."))
            }
        }

        if let context = codexPluginSelectionContextText(for: selectedSummaries) {
            items.append(.text(context))
        }

        return items
    }

    private func sessionHasLiveRuntime(_ sessionID: String?) -> Bool {
        guard let normalizedSessionID = normalizedSessionID(sessionID) else {
            return false
        }

        let state = sessionExecutionStateBySessionID[normalizedSessionID]
        let runtime = sessionRuntimesBySessionID[normalizedSessionID]
        return state?.hasActiveTurn == true
            || state?.pendingPermissionRequest != nil
            || state?.hasLiveClaudeProcess == true
            || runtime?.hasActiveTurn == true
            || runtime?.hasLiveClaudeProcess == true
    }

    private func liveRuntimeSessionCount(excluding sessionID: String? = nil) -> Int {
        let excludedSessionID = normalizedSessionID(sessionID)
        let sessionIDs = Set(sessionExecutionStateBySessionID.keys).union(sessionRuntimesBySessionID.keys)
        return sessionIDs.reduce(into: 0) { total, runtimeSessionID in
            guard runtimeSessionID != excludedSessionID else { return }
            let state = sessionExecutionStateBySessionID[runtimeSessionID]
            let runtime = sessionRuntimesBySessionID[runtimeSessionID]
            if state?.hasActiveTurn == true
                || state?.pendingPermissionRequest != nil
                || state?.hasLiveClaudeProcess == true
                || runtime?.hasActiveTurn == true
                || runtime?.hasLiveClaudeProcess == true {
                total += 1
            }
        }
    }

    private func hasActiveOllamaRuntimeUsage() -> Bool {
        var candidateSessionIDs = Set(sessionExecutionStateBySessionID.keys)
        candidateSessionIDs.formUnion(sessionRuntimesBySessionID.keys)
        if let selectedSessionID = normalizedSessionID(selectedSessionID) {
            candidateSessionIDs.insert(selectedSessionID)
        }
        if let rootSessionID = normalizedSessionID(rootRuntime.currentSessionID) {
            candidateSessionIDs.insert(rootSessionID)
        }

        return candidateSessionIDs.contains { runtimeSessionID in
            let state = sessionExecutionStateBySessionID[runtimeSessionID]
            let runtime = runtime(for: runtimeSessionID)
                ?? (sessionsMatch(rootRuntime.currentSessionID, runtimeSessionID) ? rootRuntime : nil)
            let session = sessions.first(where: { sessionsMatch($0.id, runtimeSessionID) })
            let runtimeBackend = runtime?.backend ?? session.map { self.backend(for: $0) }
            guard runtimeBackend == .ollamaLocal else { return false }
            return state?.hasActiveTurn == true
                || state?.pendingPermissionRequest != nil
                || runtime?.hasActiveTurn == true
        }
    }

    private func stopManagedLocalOllamaRuntimeIfIdle() async {
        guard !hasActiveOllamaRuntimeUsage() else { return }
        await LocalAIRuntimeManager.shared.stop()
    }

    private func ensureLiveRuntimeCapacity(for sessionID: String?) throws {
        guard !sessionHasLiveRuntime(sessionID),
              liveRuntimeSessionCount(excluding: sessionID) >= Self.maxConcurrentLiveSessions else {
            return
        }

        throw AssistantPromptRoutingError.liveSessionLimitReached(limit: Self.maxConcurrentLiveSessions)
    }

    private func sessionIDBoundToRuntime(_ runtime: CodexAssistantRuntime) -> String? {
        sessionRuntimesBySessionID.first(where: { $0.value === runtime })?.key
    }

    private func canonicalThreadID(forProviderSessionID providerSessionID: String?) -> String? {
        guard let normalizedProviderSessionID = normalizedSessionID(providerSessionID) else {
            return nil
        }
        return sessions.first(where: {
            normalizedSessionID($0.activeProviderSessionID) == normalizedProviderSessionID
                || $0.providerBindingsByBackend.contains(where: {
                    normalizedSessionID($0.providerSessionID) == normalizedProviderSessionID
                })
        })?.id
    }

    private func managedSessionID(for runtime: CodexAssistantRuntime) -> String? {
        Self.resolvedManagedSessionID(
            boundSessionID: sessionIDBoundToRuntime(runtime),
            canonicalThreadID: canonicalThreadID(forProviderSessionID: runtime.currentSessionID),
            runtimeSessionID: runtime.currentSessionID
        )
    }

    private func moveRuntimeRegistration(
        from previousSessionID: String?,
        to nextSessionID: String?,
        runtime: CodexAssistantRuntime
    ) {
        let normalizedPreviousSessionID = normalizedSessionID(previousSessionID)
        let normalizedNextSessionID = normalizedSessionID(nextSessionID)

        if normalizedPreviousSessionID == normalizedNextSessionID {
            if let normalizedNextSessionID {
                sessionRuntimesBySessionID[normalizedNextSessionID] = runtime
            }
            return
        }

        if let normalizedPreviousSessionID {
            sessionRuntimesBySessionID.removeValue(forKey: normalizedPreviousSessionID)
        }

        if let normalizedNextSessionID {
            sessionRuntimesBySessionID[normalizedNextSessionID] = runtime
            if let normalizedPreviousSessionID,
               let existingState = sessionExecutionStateBySessionID.removeValue(forKey: normalizedPreviousSessionID) {
                sessionExecutionStateBySessionID[normalizedNextSessionID] = existingState
            }
        }
    }

    private func resolveRuntimeSessionID(
        for runtime: CodexAssistantRuntime,
        preferredSessionID: String?,
        requestSessionID: String? = nil
    ) -> String? {
        if let requestSessionID = requestSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            return canonicalThreadID(forProviderSessionID: requestSessionID) ?? requestSessionID
        }
        if let runtimeSessionID = runtime.currentSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            return canonicalThreadID(forProviderSessionID: runtimeSessionID)
                ?? sessionIDBoundToRuntime(runtime)
                ?? runtimeSessionID
        }
        return sessionIDBoundToRuntime(runtime)
            ?? preferredSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    private func resolvedMutationSessionID(
        for runtime: CodexAssistantRuntime?,
        preferredSessionID: String?,
        explicitSessionID: String?
    ) -> String? {
        if let runtime {
            return resolveRuntimeSessionID(
                for: runtime,
                preferredSessionID: preferredSessionID,
                requestSessionID: explicitSessionID
            ) ?? preferredSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                ?? explicitSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        }

        return canonicalThreadID(forProviderSessionID: explicitSessionID)
            ?? explicitSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? preferredSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    private func remappedTranscriptMutation(
        _ mutation: AssistantTranscriptMutation,
        runtime: CodexAssistantRuntime?,
        preferredSessionID: String?
    ) -> AssistantTranscriptMutation {
        let sessionID: String?
        switch mutation {
        case .reset(let explicitSessionID):
            sessionID = resolvedMutationSessionID(
                for: runtime,
                preferredSessionID: preferredSessionID,
                explicitSessionID: explicitSessionID
            )
        case .upsert(_, let explicitSessionID):
            sessionID = resolvedMutationSessionID(
                for: runtime,
                preferredSessionID: preferredSessionID,
                explicitSessionID: explicitSessionID
            )
        case .appendDelta(_, let explicitSessionID, _, _, _, _, _):
            sessionID = resolvedMutationSessionID(
                for: runtime,
                preferredSessionID: preferredSessionID,
                explicitSessionID: explicitSessionID
            )
        }

        return Self.remappedTranscriptMutation(mutation, sessionID: sessionID)
    }

    private func remappedTimelineMutation(
        _ mutation: AssistantTimelineMutation,
        runtime: CodexAssistantRuntime?,
        preferredSessionID: String?
    ) -> AssistantTimelineMutation {
        let sessionID: String?
        switch mutation {
        case .reset(let explicitSessionID):
            sessionID = resolvedMutationSessionID(
                for: runtime,
                preferredSessionID: preferredSessionID,
                explicitSessionID: explicitSessionID
            )
        case .upsert(let item):
            sessionID = resolvedMutationSessionID(
                for: runtime,
                preferredSessionID: preferredSessionID,
                explicitSessionID: item.sessionID
            )
        case .appendTextDelta(_, let explicitSessionID, _, _, _, _, _, _, _, _):
            sessionID = resolvedMutationSessionID(
                for: runtime,
                preferredSessionID: preferredSessionID,
                explicitSessionID: explicitSessionID
            )
        case .remove:
            sessionID = nil
        }

        return Self.remappedTimelineMutation(mutation, sessionID: sessionID)
    }

    private func shouldIgnoreTimelineResetMutation(
        _ mutation: AssistantTimelineMutation,
        runtime: CodexAssistantRuntime?,
        preferredSessionID: String?
    ) -> Bool {
        let resolvedManagedSessionID = runtime.flatMap { self.managedSessionID(for: $0) }
            ?? preferredSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let managedSession = resolvedManagedSessionID.flatMap { sessionID in
            sessions.first(where: { sessionsMatch($0.id, sessionID) })
        }
        return Self.shouldIgnoreTimelineResetMutation(mutation, session: managedSession)
    }

    static func remappedTranscriptMutation(
        _ mutation: AssistantTranscriptMutation,
        sessionID: String?
    ) -> AssistantTranscriptMutation {
        switch mutation {
        case .reset:
            return .reset(sessionID: sessionID)
        case .upsert(let entry, _):
            return .upsert(entry, sessionID: sessionID)
        case .appendDelta(let id, _, let role, let delta, let createdAt, let emphasis, let isStreaming):
            return .appendDelta(
                id: id,
                sessionID: sessionID,
                role: role,
                delta: delta,
                createdAt: createdAt,
                emphasis: emphasis,
                isStreaming: isStreaming
            )
        }
    }

    static func remappedTimelineMutation(
        _ mutation: AssistantTimelineMutation,
        sessionID: String?
    ) -> AssistantTimelineMutation {
        switch mutation {
        case .reset:
            return .reset(sessionID: sessionID)
        case .upsert(let item):
            var remappedItem = item
            remappedItem.sessionID = sessionID
            return .upsert(remappedItem)
        case .appendTextDelta(
            let id,
            _,
            let turnID,
            let kind,
            let delta,
            let createdAt,
            let updatedAt,
            let isStreaming,
            let emphasis,
            let source
        ):
            return .appendTextDelta(
                id: id,
                sessionID: sessionID,
                turnID: turnID,
                kind: kind,
                delta: delta,
                createdAt: createdAt,
                updatedAt: updatedAt,
                isStreaming: isStreaming,
                emphasis: emphasis,
                source: source
            )
        case .remove:
            return mutation
        }
    }

    static func shouldIgnoreTimelineResetMutation(
        _ mutation: AssistantTimelineMutation,
        session: AssistantSessionSummary?
    ) -> Bool {
        guard case .reset(let explicitSessionID) = mutation,
              explicitSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty == nil,
              session?.isCanonicalThread == true else {
            return false
        }
        return true
    }

    private func withSessionExecutionState(
        for sessionID: String?,
        _ mutate: (inout AssistantSessionExecutionState) -> Void
    ) {
        guard let normalizedSessionID = normalizedSessionID(sessionID) else { return }
        var state = sessionExecutionStateBySessionID[normalizedSessionID] ?? AssistantSessionExecutionState()
        mutate(&state)
        sessionExecutionStateBySessionID[normalizedSessionID] = state
        if sessionsMatch(selectedSessionID, normalizedSessionID) {
            syncSelectedSessionExecutionState()
        } else {
            recomputeAggregatedSubagents()
        }
    }

    private func selectedSessionExecutionState() -> AssistantSessionExecutionState? {
        guard let normalizedSessionID = normalizedSessionID(selectedSessionID) else {
            return nil
        }
        return sessionExecutionStateBySessionID[normalizedSessionID]
    }

    private func syncSelectedSessionExecutionState() {
        let state = selectedSessionExecutionState() ?? AssistantSessionExecutionState()
        planEntries = state.planEntries
        toolCalls = state.toolCalls
        recentToolCalls = state.recentToolCalls
        pendingPermissionRequest = state.pendingPermissionRequest
        // Preserve the .listening phase during active voice capture so that
        // runtime HUD updates (e.g. a previous turn going idle) don't reset
        // the UI away from the listening indicator while the user is still
        // holding the voice shortcut.
        if hudState.phase != .listening {
            hudState = state.hudState ?? .idle
        }
        proposedPlan = state.proposedPlan
        proposedPlanSessionID = state.proposedPlan?.nonEmpty == nil ? nil : selectedSessionID
        recomputeAggregatedSubagents()
    }

    private func stagePendingOutgoingMessage(
        prompt: String,
        attachments: [AssistantAttachment],
        for sessionID: String
    ) {
        let pendingMessage = AssistantPendingOutgoingMessage(
            text: prompt,
            imageAttachments: attachments.filter(\.isImage).map(\.data),
            createdAt: Date()
        )
        withSessionExecutionState(for: sessionID) { state in
            state.pendingOutgoingMessage = pendingMessage
            state.awaitingAssistantStart = true
            state.hudState = AssistantHUDState(
                phase: .thinking,
                title: "Thinking",
                detail: "Sending your message"
            )
        }
    }

    private func enqueueQueuedPrompt(
        _ prompt: AssistantQueuedPrompt,
        for sessionID: String
    ) {
        withSessionExecutionState(for: sessionID) { state in
            state.queuedPrompts.append(prompt)
            state.pendingOutgoingMessage = nil
            state.awaitingAssistantStart = false
        }
    }

    private func dequeueQueuedPrompt(for sessionID: String?) -> AssistantQueuedPrompt? {
        var queuedPrompt: AssistantQueuedPrompt?
        withSessionExecutionState(for: sessionID) { state in
            guard !state.queuedPrompts.isEmpty else { return }
            queuedPrompt = state.queuedPrompts.removeFirst()
            state.awaitingAssistantStart = true
            state.hudState = AssistantHUDState(
                phase: .thinking,
                title: "Thinking",
                detail: "Sending your queued message"
            )
        }
        return queuedPrompt
    }

    @discardableResult
    private func discardQueuedPrompts(for sessionID: String?) -> Int {
        var discardedCount = 0
        withSessionExecutionState(for: sessionID) { state in
            discardedCount = state.queuedPrompts.count
            state.queuedPrompts.removeAll()
        }
        return discardedCount
    }

    private func clearPendingOutgoingMessage(for sessionID: String?) {
        withSessionExecutionState(for: sessionID) { state in
            state.pendingOutgoingMessage = nil
        }
    }

    private func clearAwaitingAssistantStart(for sessionID: String?) {
        withSessionExecutionState(for: sessionID) { state in
            state.awaitingAssistantStart = false
        }
    }

    private func clearPendingSendState(for sessionID: String?) {
        withSessionExecutionState(for: sessionID) { state in
            state.pendingOutgoingMessage = nil
            state.awaitingAssistantStart = false
        }
    }

    private func processQueuedPromptsAfterTurnCompletion(
        for sessionID: String?,
        status: AssistantTurnCompletionStatus
    ) async {
        guard let sessionID else { return }

        switch status {
        case .completed:
            guard let queuedPrompt = dequeueQueuedPrompt(for: sessionID) else { return }
            do {
                try await sendQueuedPrompt(queuedPrompt, for: sessionID)
            } catch {
                clearPendingSendState(for: sessionID)
                let discardedCount = discardQueuedPrompts(for: sessionID)
                let friendlyErrorText = Self.humanizedAssistantErrorMessage(error.localizedDescription)
                let errorMessage = discardedCount > 0
                    ? "\(friendlyErrorText)\n\nOpenAssist did not send the remaining queued follow-up messages."
                    : friendlyErrorText
                lastStatusMessage = errorMessage
                withSessionExecutionState(for: sessionID) { state in
                    state.hudState = AssistantHUDState(
                        phase: .failed,
                        title: "Queued send failed",
                        detail: errorMessage
                    )
                }
                appendTranscriptEntry(
                    AssistantTranscriptEntry(
                        role: .error,
                        text: errorMessage,
                        emphasis: true
                    ),
                    sessionID: sessionID
                )
                appendTimelineItem(
                    .system(
                        sessionID: sessionID,
                        text: errorMessage,
                        createdAt: Date(),
                        emphasis: true,
                        source: .runtime
                    )
                )
            }
        case .interrupted, .failed:
            let discardedCount = discardQueuedPrompts(for: sessionID)
            guard discardedCount > 0 else { return }
            let message = discardedCount == 1
                ? "A queued follow-up was not sent because the previous turn did not finish."
                : "\(discardedCount) queued follow-up messages were not sent because the previous turn did not finish."
            lastStatusMessage = message
        }
    }

    private func sendQueuedPrompt(
        _ queuedPrompt: AssistantQueuedPrompt,
        for sessionID: String
    ) async throws {
        let runtimeForSession = ensureRuntime(for: sessionID)
        runtimeForSession.setSelectedCodexPluginIDs(queuedPrompt.selectedPluginIDs)
        try await runtimeForSession.refreshCurrentSessionConfiguration(
            cwd: resolvedSessionCWD(for: sessionID),
            preferredModelID: queuedPrompt.preferredModelID
        )
        let resumeContext = resumeContextIfNeeded(for: sessionID)
        let memoryContext = try memoryContextForPrompt(
            sessionID: sessionID,
            prompt: queuedPrompt.text,
            automationJob: queuedPrompt.automationJob
        )
        let pluginInputItems = await resolvedCodexPluginPromptItems(
            selectedPluginIDs: queuedPrompt.selectedPluginIDs,
            prompt: queuedPrompt.text,
            backend: runtimeForSession.backend
        )

        recordOwnedSessionID(sessionID)
        ensureSessionVisible(sessionID)
        scheduleTrackedCodeCheckpointStartIfNeeded(for: sessionID)
        try await runtimeForSession.sendPrompt(
            queuedPrompt.text,
            attachments: queuedPrompt.attachments,
            preferredModelID: queuedPrompt.preferredModelID,
            modelSupportsImageInput: queuedPrompt.modelSupportsImageInput,
            resumeContext: resumeContext,
            memoryContext: memoryContext,
            submittedSlashCommand: queuedPrompt.submittedSlashCommand,
            structuredInputItems: pluginInputItems
        )
        await commitPendingHistoryEditIfNeeded(for: sessionID)
        pendingResumeContextSessionIDs.remove(sessionID)
        pendingResumeContextSnapshotsBySessionID.removeValue(forKey: sessionID)
        pendingResumeContextMetadataBySessionID.removeValue(forKey: sessionID)
    }

    private func memoryContextForPrompt(
        sessionID: String,
        prompt: String,
        automationJob: ScheduledJob?
    ) throws -> String? {
        guard settings.assistantMemoryEnabled else {
            refreshMemoryState(for: sessionID)
            return nil
        }

        if activeAssistantNotesRuntimeContext() != nil {
            currentMemoryFileURL = nil
            updateMemoryStatus(base: "Using live project notes")
            return nil
        }

        let builtMemory: AssistantBuiltMemoryContext
        if let automationJob {
            builtMemory = try automationMemoryService.prepareAutomationTurnContext(
                job: automationJob,
                threadID: sessionID,
                prompt: prompt,
                cwd: resolvedSessionCWD(for: sessionID),
                summaryMaxChars: settings.assistantMemorySummaryMaxChars
            )
        } else {
            let projectTurnContext = try projectMemoryService.turnContext(
                forThreadID: sessionID,
                fallbackCWD: resolvedSessionCWD(for: sessionID),
                prompt: prompt
            )
            builtMemory = try memoryRetrievalService.prepareTurnContext(
                threadID: sessionID,
                prompt: prompt,
                cwd: resolvedSessionCWD(for: sessionID),
                summaryMaxChars: settings.assistantMemorySummaryMaxChars,
                longTermScope: projectTurnContext?.scope,
                projectContextBlock: projectTurnContext?.projectContextBlock,
                statusBase: projectTurnContext == nil ? "Using session memory" : "Using thread + project memory"
            )
        }
        currentMemoryFileURL = builtMemory.fileURL
        updateMemoryStatus(base: builtMemory.statusMessage)
        return builtMemory.summary
    }

    private func shouldPublishVisibleRuntimeSurface(
        from runtime: CodexAssistantRuntime,
        preferredSessionID: String?
    ) -> Bool {
        guard runtime.backend == visibleAssistantBackend else {
            return false
        }

        if let selectedSessionID = selectedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            guard let runtimeSessionID = resolveRuntimeSessionID(
                for: runtime,
                preferredSessionID: preferredSessionID
            ) else {
                return false
            }
            return sessionsMatch(runtimeSessionID, selectedSessionID)
        }

        return runtime === rootRuntime
            || resolveRuntimeSessionID(for: runtime, preferredSessionID: preferredSessionID) == nil
    }

    private func providerSurfaceSnapshot(
        threadID: String?,
        backend: AssistantRuntimeBackend
    ) -> AssistantProviderRuntimeSurfaceSnapshot? {
        guard let normalizedThreadID = normalizedSessionID(threadID) else { return nil }
        return providerRuntimeSurfaceByThreadID[normalizedThreadID]?[backend]
    }

    private func cachedAvailableModels(
        threadID: String?,
        backend: AssistantRuntimeBackend
    ) -> [AssistantModelOption] {
        let threadModels = providerSurfaceSnapshot(threadID: threadID, backend: backend)?.availableModels ?? []
        if !threadModels.isEmpty {
            return threadModels
        }
        return providerAvailableModelsByBackend[backend] ?? []
    }

    private func hasCachedModels(
        threadID: String?,
        backend: AssistantRuntimeBackend
    ) -> Bool {
        !cachedAvailableModels(threadID: threadID, backend: backend).isEmpty
    }

    private func updateProviderSurfaceSnapshot(
        threadID: String?,
        backend: AssistantRuntimeBackend,
        _ mutate: (inout AssistantProviderRuntimeSurfaceSnapshot) -> Void
    ) {
        guard let normalizedThreadID = normalizedSessionID(threadID) else { return }
        var snapshots = providerRuntimeSurfaceByThreadID[normalizedThreadID] ?? [:]
        var snapshot = snapshots[backend] ?? .empty
        mutate(&snapshot)
        snapshots[backend] = snapshot
        providerRuntimeSurfaceByThreadID[normalizedThreadID] = snapshots
    }

    private func scopedProviderSurfaceModelID(
        threadID: String?,
        backend: AssistantRuntimeBackend,
        prefersVisibleSelection: Bool = false
    ) -> String? {
        if prefersVisibleSelection, visibleAssistantBackend == backend {
            return selectedModelID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        }

        guard let normalizedThreadID = normalizedSessionID(threadID),
              let session = sessions.first(where: { sessionsMatch($0.id, normalizedThreadID) }) else {
            return prefersVisibleSelection
                ? selectedModelID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                : nil
        }

        if session.isProviderIndependentThreadV2 {
            return session.providerBinding(for: backend)?
                .latestModelID?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty
        }

        guard self.backend(for: session) == backend else {
            return prefersVisibleSelection
                ? selectedModelID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                : nil
        }

        return session.latestModel?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
    }

    private func restoreVisibleProviderSurface(
        threadID: String?,
        backend: AssistantRuntimeBackend,
        session: AssistantSessionSummary? = nil
    ) {
        let resolvedSession = session ?? threadID.flatMap { threadID in
            sessions.first(where: { sessionsMatch($0.id, threadID) })
        }
        let binding = resolvedSession?.providerBinding(for: backend)

        if let snapshot = providerSurfaceSnapshot(threadID: threadID, backend: backend) {
            let resolvedModels = snapshot.availableModels.isEmpty
                ? cachedAvailableModels(threadID: threadID, backend: backend)
                : snapshot.availableModels
            let resolvedModelID = Self.resolvedModelSelection(
                from: resolvedSession,
                backend: backend,
                availableModels: resolvedModels,
                preferredModelID: settings.assistantPreferredModelID.nonEmpty,
                surfaceModelID: snapshot.selectedModelID
            )
            accountSnapshot = snapshot.accountSnapshot
            visibleProviderSurfaceBackend = backend
            availableModels = resolvedModels
            tokenUsage = snapshot.tokenUsage
            rateLimits = snapshot.rateLimits
            selectedModelID = resolvedModelID
            runtime.setPreferredModelID(resolvedModelID)
            runtimeHealth.selectedModelID = resolvedModelID
            return
        }

        let fallbackModelID: String?
        if resolvedSession?.isProviderIndependentThreadV2 == true {
            fallbackModelID = binding?.latestModelID
        } else {
            fallbackModelID = binding?.latestModelID
                ?? resolvedSession?.latestModel
                ?? settings.assistantPreferredModelID.nonEmpty
        }

        tokenUsage = .empty
        rateLimits = .empty
        visibleProviderSurfaceBackend = backend
        availableModels = cachedAvailableModels(threadID: threadID, backend: backend)
        selectedModelID = fallbackModelID
        runtime.setPreferredModelID(fallbackModelID)
        runtimeHealth.selectedModelID = fallbackModelID
    }

    private func restoreVisibleProviderState(for session: AssistantSessionSummary?) {
        guard let session else { return }
        let providerBackend = backend(for: session)
        restoreVisibleProviderSurface(
            threadID: session.id,
            backend: providerBackend,
            session: session
        )
        restoreSessionConfiguration(from: session)
    }

    private func recomputeAggregatedSubagents() {
        subagents = sessionExecutionStateBySessionID.values.flatMap(\.subagents).map { agent in
            guard let threadID = normalizedSessionID(agent.threadID),
                  let childState = sessionExecutionStateBySessionID[threadID] else {
                return agent
            }

            var mergedAgent = agent
            mergedAgent.planEntries = childState.planEntries
            return mergedAgent
        }
    }

    private func composerStorageKey(for sessionID: String?) -> String {
        normalizedSessionID(sessionID) ?? "__openassist-new-thread__"
    }

    private func storeComposerDraft(_ draft: String, for sessionID: String?) {
        let key = composerStorageKey(for: sessionID)
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            composerDraftBySessionID.removeValue(forKey: key)
        } else {
            composerDraftBySessionID[key] = draft
        }
    }

    private func storeAttachments(_ attachments: [AssistantAttachment], for sessionID: String?) {
        let key = composerStorageKey(for: sessionID)
        if attachments.isEmpty {
            attachmentsBySessionID.removeValue(forKey: key)
        } else {
            attachmentsBySessionID[key] = attachments
        }
    }

    private func restoreComposerState(for sessionID: String?) {
        let key = composerStorageKey(for: sessionID)
        isRestoringComposerState = true
        promptDraft = composerDraftBySessionID[key] ?? ""
        attachments = attachmentsBySessionID[key] ?? []
        isRestoringComposerState = false
    }

    private func bindRuntimeCallbacks(
        _ runtime: CodexAssistantRuntime,
        preferredSessionID: String?
    ) {
        runtime.onHealthUpdate = { [weak self, weak runtime] health in
            Task { @MainActor in
                guard let self, let runtime else { return }
                if self.shouldPublishVisibleRuntimeSurface(from: runtime, preferredSessionID: preferredSessionID) {
                    self.runtimeHealth = health
                    switch health.availability {
                    case .installRequired, .loginRequired, .failed, .unavailable:
                        self.isLoadingModels = false
                    case .ready, .active:
                        if let detail = health.detail?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !detail.isEmpty,
                           !detail.localizedCaseInsensitiveContains("loading model") {
                            self.isLoadingModels = false
                        }
                    default:
                        break
                    }
                }

                if let sessionID = self.resolveRuntimeSessionID(for: runtime, preferredSessionID: preferredSessionID) {
                    self.withSessionExecutionState(for: sessionID) { state in
                        state.hasActiveTurn = runtime.hasActiveTurn
                    }
                }
            }
        }
        runtime.onTranscript = { [weak self, weak runtime] entry in
            Task { @MainActor in
                guard let self, let runtime else { return }
                let runtimeSessionID = self.resolveRuntimeSessionID(
                    for: runtime,
                    preferredSessionID: preferredSessionID
                ) ?? self.selectedSessionID
                self.appendTranscriptEntry(entry, sessionID: runtimeSessionID)
            }
        }
        runtime.onTranscriptMutation = { [weak self, weak runtime] mutation in
            Task { @MainActor in
                guard let self else { return }
                self.applyTranscriptMutation(
                    self.remappedTranscriptMutation(
                        mutation,
                        runtime: runtime,
                        preferredSessionID: preferredSessionID
                    )
                )
            }
        }
        runtime.onTimelineMutation = { [weak self, weak runtime] mutation in
            Task { @MainActor in
                guard let self else { return }
                guard !self.shouldIgnoreTimelineResetMutation(
                    mutation,
                    runtime: runtime,
                    preferredSessionID: preferredSessionID
                ) else {
                    return
                }
                self.applyTimelineMutation(
                    self.remappedTimelineMutation(
                        mutation,
                        runtime: runtime,
                        preferredSessionID: preferredSessionID
                    )
                )
            }
        }
        runtime.onHUDUpdate = { [weak self, weak runtime] state in
            Task { @MainActor in
                guard let self, let runtime else { return }
                if let sessionID = self.resolveRuntimeSessionID(for: runtime, preferredSessionID: preferredSessionID) {
                    self.withSessionExecutionState(for: sessionID) { executionState in
                        let shouldPreservePendingThinking =
                            executionState.awaitingAssistantStart
                            && !runtime.hasActiveTurn
                            && state.phase.isActive
                        if !shouldPreservePendingThinking {
                            executionState.hudState = state
                        }
                        executionState.hasActiveTurn = runtime.hasActiveTurn
                        executionState.hasLiveClaudeProcess = runtime.hasLiveClaudeProcess
                        if runtime.hasActiveTurn {
                            executionState.awaitingAssistantStart = false
                        }
                    }
                } else if self.sessionRuntimesBySessionID.isEmpty, self.hudState.phase != .listening {
                    self.hudState = state
                }
            }
        }
        runtime.onExecutionStateUpdate = { [weak self, weak runtime] hasActiveTurn, hasLiveClaudeProcess in
            Task { @MainActor in
                guard let self, let runtime else { return }
                let resolvedSessionID = self.resolveRuntimeSessionID(
                    for: runtime,
                    preferredSessionID: preferredSessionID
                )
                self.withSessionExecutionState(for: resolvedSessionID) { state in
                    state.hasActiveTurn = hasActiveTurn
                    state.hasLiveClaudeProcess = hasLiveClaudeProcess
                    if !hasActiveTurn {
                        state.awaitingAssistantStart = false
                    }
                }
            }
        }
        runtime.onTurnCompletion = { [weak self, weak runtime] status in
            Task { @MainActor in
                guard let self, let runtime else { return }
                let completionSessionID = self.resolveRuntimeSessionID(
                    for: runtime,
                    preferredSessionID: preferredSessionID
                )
                let completionTurnID = runtime.currentTurnID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                CrashReporter.logInfo(
                    "AssistantStore turn completion received sessionID=\(completionSessionID ?? "missing") status=\(String(describing: status))"
                )
                if let completionSessionID {
                    self.flushPersistedHistoryIfNeeded(sessionID: completionSessionID)
                }
                if let completionSessionID {
                    self.withSessionExecutionState(for: completionSessionID) { state in
                        state.hasActiveTurn = false
                        state.hasLiveClaudeProcess = runtime.hasLiveClaudeProcess
                        state.awaitingAssistantStart = false
                        state.pendingOutgoingMessage = nil
                        state.latestRemoteAttentionEvent = self.remoteAttentionEvent(
                            for: status,
                            sessionID: completionSessionID,
                            turnID: completionTurnID
                        )
                        self.finalizeToolCallsForTurn(state: &state, status: status)
                        if state.hudState?.phase == .waitingForPermission {
                            state.hudState = .idle
                        }
                    }
                }
                await self.finalizeTrackedCodeCheckpoint(
                    for: completionSessionID,
                    turnID: completionTurnID,
                    status: status
                )
                if let completionSessionID {
                    await self.refreshCodeTrackingState(for: completionSessionID)
                }
                await self.notifyBackgroundTurnCompletionIfNeeded(
                    sessionID: completionSessionID,
                    turnID: completionTurnID,
                    status: status
                )
                self.onTurnCompletion?(status)
                await self.processQueuedPromptsAfterTurnCompletion(
                    for: completionSessionID,
                    status: status
                )
                Task { @MainActor [weak self] in
                    await self?.handleProjectMemoryCheckpoint(for: completionSessionID)
                    await self?.handleThreadMemoryCheckpoint(
                        for: completionSessionID,
                        status: status
                    )
                }
            }
        }
        runtime.onModeRestriction = { [weak self] event in
            Task { @MainActor in
                self?.blockedModeSwitchSuggestion = Self.modeSwitchSuggestion(for: event)
                self?.refreshModeSwitchSuggestion()
            }
        }
        runtime.onPlanUpdate = { [weak self, weak runtime] sessionID, entries in
            Task { @MainActor in
                guard let self, let runtime else { return }
                self.withSessionExecutionState(
                    for: sessionID ?? self.resolveRuntimeSessionID(for: runtime, preferredSessionID: preferredSessionID)
                ) { state in
                    state.planEntries = entries
                }
            }
        }
        runtime.onToolCallUpdate = { [weak self, weak runtime] calls in
            Task { @MainActor in
                guard let self, let runtime else { return }
                self.updateToolCallActivity(
                    calls,
                    sessionID: self.resolveRuntimeSessionID(for: runtime, preferredSessionID: preferredSessionID)
                )
            }
        }
        runtime.onPermissionRequest = { [weak self, weak runtime] request in
            Task { @MainActor in
                guard let self, let runtime else { return }
                let resolvedSessionID = self.resolveRuntimeSessionID(
                    for: runtime,
                    preferredSessionID: preferredSessionID,
                    requestSessionID: request?.sessionID
                )

                if let request,
                   let toolKind = request.toolKind,
                   self.settings.assistantAlwaysApprovedToolKinds.contains(toolKind) {
                    let sessionOption = request.options.first(where: { $0.id == "acceptForSession" })
                        ?? request.options.first(where: { $0.isDefault })
                    if let optionID = sessionOption?.id {
                        await self.prepareTrackedCodeCheckpointIfNeeded(
                            for: request,
                            optionID: optionID
                        )
                        await runtime.respondToPermissionRequest(optionID: optionID)
                        return
                    }
                }

                self.withSessionExecutionState(for: resolvedSessionID) { state in
                    let previousRequestID = state.pendingPermissionRequest?.id
                    state.pendingPermissionRequest = request
                    state.hasActiveTurn = runtime.hasActiveTurn
                    state.hasLiveClaudeProcess = runtime.hasLiveClaudeProcess
                    if let request, previousRequestID != request.id {
                        state.latestRemoteAttentionEvent = self.remotePermissionAttentionEvent(for: request)
                    }
                    if request != nil {
                        state.awaitingAssistantStart = false
                        let waitingTitle = request?.toolKind == "userInput"
                            ? "Waiting for input"
                            : "Waiting for approval"
                        state.hudState = AssistantHUDState(
                            phase: .waitingForPermission,
                            title: waitingTitle,
                            detail: request?.toolTitle
                        )
                    }
                }
            }
        }
        runtime.onSessionChange = { [weak self, weak runtime] sessionID in
            Task { @MainActor in
                guard let self, let runtime else { return }
                let previousSessionID = self.sessionIDBoundToRuntime(runtime) ?? preferredSessionID
                let resolvedPreviousThreadID = self.canonicalThreadID(forProviderSessionID: previousSessionID)
                    ?? previousSessionID
                if let resolvedPreviousThreadID,
                   let existingSession = self.sessions.first(where: {
                       self.sessionsMatch($0.id, resolvedPreviousThreadID)
                   }),
                   existingSession.isCanonicalThread {
                    if Self.shouldApplyProviderSessionChange(
                        for: existingSession,
                        runtimeBackend: runtime.backend,
                        providerSessionID: sessionID
                    ) {
                        self.updateProviderLink(
                            forThreadID: existingSession.id,
                            backend: runtime.backend,
                            providerSessionID: sessionID
                        )
                    }
                    let visibleThreadID = existingSession.id
                    let shouldSelectSession = self.sessionsMatch(self.selectedSessionID, previousSessionID)
                        || self.sessionsMatch(self.selectedSessionID, visibleThreadID)
                        || (self.selectedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                    if shouldSelectSession {
                        self.selectedSessionID = visibleThreadID
                    }
                    if self.sessionsMatch(self.transcriptSessionID, previousSessionID)
                        || self.sessionsMatch(self.transcriptSessionID, visibleThreadID)
                        || self.transcriptSessionID == nil {
                        self.transcriptSessionID = visibleThreadID
                    }
                    if self.timelineSessionID == nil
                        || self.sessionsMatch(self.timelineSessionID, previousSessionID)
                        || self.sessionsMatch(self.timelineSessionID, visibleThreadID) {
                        self.timelineSessionID = visibleThreadID
                    }
                    self.clearActiveProposedPlanIfNeeded(for: visibleThreadID)
                    self.ensureSessionVisible(visibleThreadID)
                    self.refreshMemoryState(for: visibleThreadID)
                    return
                }
                self.moveRuntimeRegistration(
                    from: previousSessionID,
                    to: sessionID,
                    runtime: runtime
                )

                let shouldSelectSession = self.sessionsMatch(self.selectedSessionID, previousSessionID)
                    || (self.selectedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                if shouldSelectSession {
                    self.selectedSessionID = sessionID
                }
                if self.sessionsMatch(self.transcriptSessionID, previousSessionID) || self.transcriptSessionID == nil {
                    self.transcriptSessionID = sessionID
                }
                if self.timelineSessionID == nil || self.sessionsMatch(self.timelineSessionID, previousSessionID) {
                    self.timelineSessionID = sessionID
                }
                self.clearActiveProposedPlanIfNeeded(for: sessionID)
                self.ensureSessionVisible(sessionID)
                self.refreshMemoryState(for: sessionID)
            }
        }
        runtime.onStatusMessage = { [weak self] message in
            Task { @MainActor in self?.lastStatusMessage = message }
        }
        runtime.onAccountUpdate = { [weak self, weak runtime] account in
            Task { @MainActor in
                guard let self, let runtime else { return }
                let resolvedSessionID = self.resolveRuntimeSessionID(for: runtime, preferredSessionID: preferredSessionID)
                self.updateProviderSurfaceSnapshot(
                    threadID: resolvedSessionID,
                    backend: runtime.backend
                ) { snapshot in
                    snapshot.accountSnapshot = account
                }
                guard self.shouldPublishVisibleRuntimeSurface(from: runtime, preferredSessionID: preferredSessionID) else {
                    return
                }
                self.accountSnapshot = account
            }
        }
        runtime.onTokenUsageUpdate = { [weak self, weak runtime] usage in
            Task { @MainActor in
                guard let self, let runtime else { return }
                let resolvedSessionID = self.resolveRuntimeSessionID(for: runtime, preferredSessionID: preferredSessionID)
                let shouldPublishVisibleSurface = self.shouldPublishVisibleRuntimeSurface(
                    from: runtime,
                    preferredSessionID: preferredSessionID
                )
                self.updateProviderSurfaceSnapshot(
                    threadID: resolvedSessionID,
                    backend: runtime.backend
                ) { snapshot in
                    snapshot.tokenUsage = usage
                    snapshot.selectedModelID = self.scopedProviderSurfaceModelID(
                        threadID: resolvedSessionID,
                        backend: runtime.backend,
                        prefersVisibleSelection: shouldPublishVisibleSurface
                    )
                }
                guard shouldPublishVisibleSurface else {
                    return
                }
                self.tokenUsage = usage
            }
        }
        runtime.onRateLimitsUpdate = { [weak self, weak runtime] limits in
            Task { @MainActor in
                guard let self, let runtime else { return }
                let resolvedSessionID = self.resolveRuntimeSessionID(for: runtime, preferredSessionID: preferredSessionID)
                let shouldPublishVisibleSurface = self.shouldPublishVisibleRuntimeSurface(
                    from: runtime,
                    preferredSessionID: preferredSessionID
                )
                self.updateProviderSurfaceSnapshot(
                    threadID: resolvedSessionID,
                    backend: runtime.backend
                ) { snapshot in
                    snapshot.rateLimits = limits
                    snapshot.selectedModelID = self.scopedProviderSurfaceModelID(
                        threadID: resolvedSessionID,
                        backend: runtime.backend,
                        prefersVisibleSelection: shouldPublishVisibleSurface
                    )
                }
                guard shouldPublishVisibleSurface else {
                    return
                }
                self.rateLimits = limits
            }
        }
        runtime.onSubagentUpdate = { [weak self, weak runtime] agents in
            Task { @MainActor in
                guard let self, let runtime else { return }
                self.withSessionExecutionState(
                    for: self.resolveRuntimeSessionID(for: runtime, preferredSessionID: preferredSessionID)
                ) { state in
                    state.subagents = agents
                }
            }
        }
        runtime.onModelsUpdate = { [weak self, weak runtime] models in
            Task { @MainActor in
                guard let self, let runtime else { return }
                let resolvedSessionID = self.resolveRuntimeSessionID(for: runtime, preferredSessionID: preferredSessionID)
                let shouldPublishVisibleSurface = self.shouldPublishVisibleRuntimeSurface(
                    from: runtime,
                    preferredSessionID: preferredSessionID
                )
                if !models.isEmpty {
                    self.providerAvailableModelsByBackend[runtime.backend] = models
                }
                self.updateProviderSurfaceSnapshot(
                    threadID: resolvedSessionID,
                    backend: runtime.backend
                ) { snapshot in
                    if !models.isEmpty {
                        snapshot.availableModels = models
                    }
                    snapshot.selectedModelID = self.scopedProviderSurfaceModelID(
                        threadID: resolvedSessionID,
                        backend: runtime.backend,
                        prefersVisibleSelection: shouldPublishVisibleSurface
                    )
                }
                guard shouldPublishVisibleSurface else {
                    return
                }
                let resolvedModels = models.isEmpty
                    ? self.cachedAvailableModels(threadID: resolvedSessionID, backend: runtime.backend)
                    : models
                self.visibleProviderSurfaceBackend = runtime.backend
                self.availableModels = resolvedModels
                self.applyPreferredModelSelection(using: resolvedModels)
                self.restoreSessionConfiguration(from: self.selectedSession)
                self.updateProviderSurfaceSnapshot(
                    threadID: resolvedSessionID,
                    backend: runtime.backend
                ) { snapshot in
                    if !models.isEmpty {
                        snapshot.availableModels = models
                    }
                    snapshot.selectedModelID = self.selectedModelID
                }
                if !resolvedModels.isEmpty {
                    self.isLoadingModels = false
                }
            }
        }
        runtime.onProposedPlan = { [weak self, weak runtime] planText in
            Task { @MainActor in
                guard let self, let runtime else { return }
                self.withSessionExecutionState(
                    for: self.resolveRuntimeSessionID(for: runtime, preferredSessionID: preferredSessionID)
                ) { state in
                    state.proposedPlan = planText
                }
            }
        }
        runtime.onTitleRequest = { [weak self, weak runtime] sessionID, userPrompt, assistantResponse in
            Task { @MainActor in
                guard let self, let runtime else { return }
                guard runtime.backend == .codex else { return }
                let resolvedSessionID = self.resolveRuntimeSessionID(
                    for: runtime,
                    preferredSessionID: preferredSessionID,
                    requestSessionID: sessionID
                ) ?? sessionID
                self.generateSessionTitle(
                    sessionID: resolvedSessionID,
                    userPrompt: userPrompt,
                    assistantResponse: assistantResponse
                )
            }
        }
    }

    private func clearRuntimeCallbacks(_ runtime: CodexAssistantRuntime) {
        runtime.onHealthUpdate = nil
        runtime.onTranscript = nil
        runtime.onTranscriptMutation = nil
        runtime.onTimelineMutation = nil
        runtime.onHUDUpdate = nil
        runtime.onPlanUpdate = nil
        runtime.onToolCallUpdate = nil
        runtime.onPermissionRequest = nil
        runtime.onSessionChange = nil
        runtime.onStatusMessage = nil
        runtime.onAccountUpdate = nil
        runtime.onModelsUpdate = nil
        runtime.onTokenUsageUpdate = nil
        runtime.onRateLimitsUpdate = nil
        runtime.onSubagentUpdate = nil
        runtime.onProposedPlan = nil
        runtime.onModeRestriction = nil
        runtime.onTurnCompletion = nil
        runtime.onExecutionStateUpdate = nil
        runtime.onTitleRequest = nil
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
            if visibleAssistantBackend.requiresLogin {
                state = accountSnapshot.isLoggedIn ? .ready : (installGuidance.codexDetected ? .needsLogin : .missingCodex)
            } else {
                state = installGuidance.codexDetected ? .ready : .missingCodex
            }
        }
        return AssistantEnvironmentSnapshot(
            state: state,
            installHelpText: runtimeHealth.detail ?? installGuidance.primaryDetail
        )
    }

    var selectedModelSummary: String {
        if let selectedModel {
            return assistantDisplayModelName(selectedModel.displayName)
        }
        if let selectedModelID = selectedModelID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            return assistantDisplayModelName(selectedModelID)
        }
        if isLoadingModels {
            return "Loading models..."
        }
        if !visibleModels.isEmpty {
            return "Select model"
        }
        return "No models"
    }

    var runtimeControlsAvailability: AssistantRuntimeControlsAvailability {
        runtimeControlsState(
            for: visibleAssistantBackend,
            availableModels: visibleModels,
            isLoadingModels: isLoadingModels,
            isBusy: hasActiveTurn
        ).availability
    }

    var runtimeControlsStatusText: String {
        runtimeControlsState(
            for: visibleAssistantBackend,
            availableModels: visibleModels,
            isLoadingModels: isLoadingModels,
            isBusy: hasActiveTurn
        ).statusText
    }

    func runtimeControlsState(
        for backend: AssistantRuntimeBackend,
        availableModels: [AssistantModelOption],
        isLoadingModels: Bool,
        isBusy: Bool
    ) -> (availability: AssistantRuntimeControlsAvailability, statusText: String) {
        if isBusy {
            return (.busy, AssistantRuntimeControlsAvailability.busy.fallbackStatusText)
        }

        if backend == visibleAssistantBackend {
            switch runtimeHealth.availability {
            case .idle, .checking, .connecting:
                return (
                    .switchingProvider,
                    AssistantRuntimeControlsAvailability.switchingProvider.fallbackStatusText
                )
            case .installRequired:
                return (.unavailable, backend.missingInstallSummary)
            case .loginRequired:
                return (.unavailable, backend.loginRequiredSummary)
            case .failed, .unavailable:
                let summary =
                    runtimeHealth.detail?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty
                    ?? runtimeHealth.summary
                return (.unavailable, summary)
            case .ready, .active:
                break
            }
        }

        let installGuidance = guidance(for: backend)
        if !installGuidance.codexDetected {
            return (.unavailable, backend.missingInstallSummary)
        }

        if isLoadingModels {
            return (
                .loadingModels,
                AssistantRuntimeControlsAvailability.loadingModels.fallbackStatusText
            )
        }

        if availableModels.isEmpty {
            return (.unavailable, "No models available")
        }

        return (.ready, "")
    }

    var visibleToolActivity: [AssistantToolCallState] {
        toolCalls + recentToolCalls
    }

    var hasToolActivity: Bool {
        !visibleToolActivity.isEmpty
    }

    var visibleModels: [AssistantModelOption] {
        Self.selectableModels(for: visibleAssistantBackend, from: availableModels)
    }

    var selectedModel: AssistantModelOption? {
        guard let selectedModelID else { return nil }
        return visibleModels.first(where: { $0.id == selectedModelID })
    }

    var selectedSubagentModel: AssistantModelOption? {
        guard let selectedSubagentModelID else { return nil }
        return visibleModels.first(where: { $0.id == selectedSubagentModelID })
    }

    var selectedSubagentModelSummary: String {
        selectedSubagentModel.map { assistantDisplayModelName($0.displayName) } ?? "Same as main model"
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

        return "The selected model \(assistantDisplayModelName(selectedModel.displayName)) cannot read image attachments. Choose a model that supports image input and try again. Attached images can still be analyzed directly when the model supports them, but live browser or app automation needs Agentic mode."
    }

    static func humanizedAssistantErrorMessage(_ rawMessage: String) -> String {
        let trimmed = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{",
              let data = trimmed.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return trimmed
        }

        for key in ["detail", "message", "error"] {
            if let text = (payload[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
                return text
            }
        }

        if let errors = payload["errors"] as? [String] {
            let joined = errors
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            if let joined = joined.nonEmpty {
                return joined
            }
        }

        return trimmed
    }

    static func isRecoverableProviderSessionErrorMessage(
        _ rawMessage: String,
        backend: AssistantRuntimeBackend
    ) -> Bool {
        let normalized = humanizedAssistantErrorMessage(rawMessage)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return false }

        let recoverableFragments: [String]
        switch backend {
        case .copilot:
            recoverableFragments = [
                "stream disconnected before completion",
                "an error occurred while processing your request",
                "include the request id",
                "codex app server stopped",
                "codex app server closed",
                "codex app server is not running",
                "github copilot exited because of a signal",
                "github copilot exited with code",
                "operation cancelled by user",
                "operation canceled by user",
                "operation was cancelled by the user",
                "operation was canceled by the user"
            ]
        case .claudeCode:
            recoverableFragments = [
                "no conversation found with session id",
                "conversation not found with session id",
                "conversation not found"
            ]
        case .codex:
            recoverableFragments = []
        case .ollamaLocal:
            recoverableFragments = []
        }

        return recoverableFragments.contains { normalized.contains($0) }
    }

    static func shouldInvalidateProviderSessionAfterUserCancellation(
        backend: AssistantRuntimeBackend,
        session: AssistantSessionSummary?
    ) -> Bool {
        guard backend == .copilot,
              let session else {
            return false
        }

        return session.isCanonicalThread
    }

    var isRuntimeReadyForConversation: Bool {
        switch runtimeHealth.availability {
        case .ready, .active:
            return true
        default:
            return false
        }
    }

    private var selectedModelIsReadyForConversation: Bool {
        guard let selectedModel else { return false }
        if visibleAssistantBackend == .ollamaLocal {
            return selectedModel.isInstalled
        }
        return true
    }

    var canStartConversation: Bool {
        isRuntimeReadyForConversation && selectedModelIsReadyForConversation
    }

    var canCreateThread: Bool {
        true
    }

    var conversationBlockedReason: String? {
        let backend = assistantBackend
        if !isRuntimeReadyForConversation {
            switch runtimeHealth.availability {
            case .idle, .checking:
                return backend.waitingToStartConversationMessage
            case .connecting:
                return backend.connectingConversationMessage
            case .installRequired:
                return backend.missingInstallSummary + "."
            case .loginRequired:
                return "\(backend.loginRequiredSummary) before starting a conversation."
            case .unavailable:
                return backend.unavailableConversationMessage
            case .failed:
                return runtimeHealth.detail ?? "\(backend.displayName) needs attention. Check Setup."
            case .ready, .active:
                break // shouldn't happen, but fall through
            }
        }
        if isLoadingModels {
            return backend.loadingModelsMessage
        }
        if visibleModels.isEmpty {
            return "No assistant models are available yet. Refresh or open Setup to check \(backend.displayName)."
        }
        if selectedModel == nil {
            return "Choose a model before starting a conversation. Then confirm the reasoning level."
        }
        if visibleAssistantBackend == .ollamaLocal,
           selectedModel?.isInstalled == false {
            let modelName = selectedModel?.displayName ?? "The selected model"
            return "\(modelName) is not installed yet. Open Setup to download it, or choose an installed local model."
        }
        if attachments.contains(where: \.isImage), !selectedModelSupportsImageInput {
            let modelName = selectedModel?.displayName ?? "The selected model"
            return "\(modelName) cannot read image attachments. Choose a model with image support, then try again."
        }
        return nil
    }

    var activeRuntimeSessionID: String? {
        guard let selectedSessionID = selectedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
              sessionActivitySnapshot(for: selectedSessionID).hasActiveTurn else {
            return nil
        }
        return selectedSessionID
    }

    var hasActiveTurn: Bool {
        sessionActivitySnapshot(for: selectedSessionID).hasActiveTurn
    }

    var hasAnyActiveTurns: Bool {
        sessionExecutionStateBySessionID.values.contains(where: \.hasActiveTurn)
    }

    private func completionNotificationOutcome(
        for status: AssistantTurnCompletionStatus
    ) -> AssistantCompletionNotificationEvent.Outcome? {
        switch status {
        case .completed:
            return .completed
        case .failed(let message):
            return .failed(reason: message)
        case .interrupted:
            return nil
        }
    }

    private func remoteAttentionEvent(
        for status: AssistantTurnCompletionStatus,
        sessionID: String,
        turnID: String?
    ) -> AssistantRemoteAttentionEvent? {
        let normalizedTurnID = turnID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let timestamp = Date()
        switch status {
        case .completed:
            let identifier = normalizedTurnID.map { "completed:\($0)" }
                ?? "completed:\(sessionID):\(timestamp.timeIntervalSince1970)"
            return AssistantRemoteAttentionEvent(
                id: identifier,
                kind: .completed,
                createdAt: timestamp,
                turnID: normalizedTurnID,
                permissionRequestID: nil,
                failureText: nil
            )
        case .failed(let message):
            let identifier = normalizedTurnID.map { "failed:\($0)" }
                ?? "failed:\(sessionID):\(timestamp.timeIntervalSince1970)"
            return AssistantRemoteAttentionEvent(
                id: identifier,
                kind: .failed,
                createdAt: timestamp,
                turnID: normalizedTurnID,
                permissionRequestID: nil,
                failureText: message.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            )
        case .interrupted:
            return nil
        }
    }

    private func remotePermissionAttentionEvent(
        for request: AssistantPermissionRequest
    ) -> AssistantRemoteAttentionEvent {
        AssistantRemoteAttentionEvent(
            id: "permission:\(request.id)",
            kind: .permissionRequired,
            createdAt: Date(),
            turnID: nil,
            permissionRequestID: request.id,
            failureText: nil
        )
    }

    private func notifyBackgroundTurnCompletionIfNeeded(
        sessionID: String?,
        turnID: String?,
        status: AssistantTurnCompletionStatus
    ) async {
        guard let normalizedSessionID = normalizedSessionID(sessionID),
              !sessionsMatch(selectedSessionID, normalizedSessionID),
              let outcome = completionNotificationOutcome(for: status) else {
            return
        }

        let sessionTitle = sessions.first(where: {
            sessionsMatch($0.id, normalizedSessionID)
        })?.title

        _ = await completionNotificationService.notify(
            for: AssistantCompletionNotificationEvent(
                sessionID: normalizedSessionID,
                sessionTitle: sessionTitle,
                turnID: turnID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
                outcome: outcome,
                isBackground: true
            )
        )
    }

    func sessionActivitySnapshot(for sessionID: String?) -> AssistantSessionActivitySnapshot {
        guard let normalizedSessionID = normalizedSessionID(sessionID) else {
            return .empty
        }
        let state = sessionExecutionStateBySessionID[normalizedSessionID] ?? AssistantSessionExecutionState()
        let runtime = sessionRuntimesBySessionID[normalizedSessionID]
        return AssistantSessionActivitySnapshot(
            sessionID: normalizedSessionID,
            hudState: state.hudState,
            hasActiveTurn: runtime?.hasActiveTurn ?? state.hasActiveTurn,
            currentTurnID: runtime?.currentTurnID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            hasLiveClaudeProcess: runtime?.hasLiveClaudeProcess ?? state.hasLiveClaudeProcess,
            canSteerActiveTurn: runtime?.canSteerActiveTurn ?? false,
            pendingPermissionRequest: state.pendingPermissionRequest,
            latestRemoteAttentionEvent: state.latestRemoteAttentionEvent,
            subagentCount: state.subagents.count,
            pendingOutgoingMessage: state.pendingOutgoingMessage,
            awaitingAssistantStart: state.awaitingAssistantStart,
            queuedPromptCount: state.queuedPrompts.count
        )
    }

    var selectedSessionCanLoadMoreHistory: Bool {
        guard let sessionID = selectedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return false
        }
        return canLoadMoreHistoryBySessionID[sessionID] ?? false
    }

    private var currentBrowserProfileContext: [String: String]? {
        guard settings.browserAutomationEnabled,
              let profile = selectedBrowserProfile else {
            return nil
        }

        return [
            "browser": profile.browser.displayName,
            "channel": profile.browser.playwrightChannel,
            "profileDir": profile.directoryName,
            "userDataDir": profile.userDataDir,
            "profileName": profile.label
        ]
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

    static func resolvedManagedSessionID(
        boundSessionID: String?,
        canonicalThreadID: String?,
        runtimeSessionID: String?
    ) -> String? {
        if let boundSessionID = boundSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            return boundSessionID
        }

        if let canonicalThreadID = canonicalThreadID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            return canonicalThreadID
        }

        return runtimeSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
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
            pendingEnvironmentRefreshPermissions = permissions
            return
        }

        isRefreshingEnvironment = true
        defer {
            isRefreshingEnvironment = false
            if let pendingPermissions = pendingEnvironmentRefreshPermissions {
                pendingEnvironmentRefreshPermissions = nil
                Task { @MainActor [weak self] in
                    await self?.refreshEnvironment(permissions: pendingPermissions)
                }
            }
        }

        let guidanceByBackend = await refreshInstallGuidanceCatalog()
        if selectedSession == nil {
            let resolvedBackend = Self.resolvedDefaultAssistantBackend(
                preferred: settings.assistantBackend,
                guidanceByBackend: guidanceByBackend
            )
            if settings.assistantBackend != resolvedBackend {
                settings.assistantBackend = resolvedBackend
            }
        }

        let requestedBackend = visibleAssistantBackend
        runtime.backend = requestedBackend
        let guidance: AssistantInstallGuidance
        if let cachedGuidance = guidanceByBackend[requestedBackend] {
            guidance = cachedGuidance
        } else {
            guidance = await installSupport.inspect(backend: requestedBackend)
        }
        guard Self.shouldApplyVisibleRuntimeRefreshResult(
            requestedBackend: requestedBackend,
            currentVisibleBackend: visibleAssistantBackend,
            runtimeBackend: runtime.backend
        ) else {
            return
        }
        installGuidance = guidance
        self.permissions = permissions

        guard guidance.codexDetected else {
            accountSnapshot = .signedOut
            visibleProviderSurfaceBackend = requestedBackend
            availableModels = []
            selectedModelID = nil
            isLoadingModels = false
            runtime.setPreferredModelID(nil)
            runtimeHealth = AssistantRuntimeHealth(
                availability: .installRequired,
                summary: requestedBackend.missingInstallSummary,
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
            guard Self.shouldApplyVisibleRuntimeRefreshResult(
                requestedBackend: requestedBackend,
                currentVisibleBackend: visibleAssistantBackend,
                runtimeBackend: runtime.backend
            ) else {
                return
            }
            let resolvedModels = details.models.isEmpty
                ? cachedAvailableModels(threadID: selectedSessionID, backend: requestedBackend)
                : details.models
            accountSnapshot = details.account
            if !details.models.isEmpty {
                providerAvailableModelsByBackend[requestedBackend] = details.models
            }
            visibleProviderSurfaceBackend = requestedBackend
            availableModels = resolvedModels
            applyPreferredModelSelection(using: resolvedModels)
            if let selectedSessionID {
                let scopedModelID = scopedProviderSurfaceModelID(
                    threadID: selectedSessionID,
                    backend: requestedBackend,
                    prefersVisibleSelection: true
                )
                updateProviderSurfaceSnapshot(
                    threadID: selectedSessionID,
                    backend: requestedBackend
                ) { snapshot in
                    snapshot.accountSnapshot = details.account
                    if !details.models.isEmpty {
                        snapshot.availableModels = details.models
                    }
                    snapshot.selectedModelID = scopedModelID
                }
            }
            runtimeHealth = details.health
            if (requestedBackend.requiresLogin ? details.account.isLoggedIn : guidance.codexDetected) && resolvedModels.isEmpty {
                runtimeHealth.detail = requestedBackend.loadingModelsMessage
            }
            if !resolvedModels.isEmpty {
                isLoadingModels = false
            }
        } catch {
            guard Self.shouldApplyVisibleRuntimeRefreshResult(
                requestedBackend: requestedBackend,
                currentVisibleBackend: visibleAssistantBackend,
                runtimeBackend: runtime.backend
            ) else {
                return
            }
            isLoadingModels = false
            let requiresLogin = requestedBackend.requiresLogin
            runtimeHealth = AssistantRuntimeHealth(
                availability: requiresLogin ? (accountSnapshot.isLoggedIn ? .failed : .loginRequired) : .failed,
                summary: requiresLogin
                    ? (accountSnapshot.isLoggedIn ? requestedBackend.needsAttentionSummary : requestedBackend.loginRequiredSummary)
                    : requestedBackend.needsAttentionSummary,
                detail: error.localizedDescription,
                runtimePath: guidance.codexPath,
                selectedModelID: selectedModelID,
                accountEmail: accountSnapshot.email,
                accountPlan: accountSnapshot.planType
            )
            lastStatusMessage = error.localizedDescription
        }
    }

    private func refreshInstallGuidanceCatalog() async -> [AssistantRuntimeBackend: AssistantInstallGuidance] {
        var catalog: [AssistantRuntimeBackend: AssistantInstallGuidance] = [:]

        await withTaskGroup(of: (AssistantRuntimeBackend, AssistantInstallGuidance).self) { group in
            for backend in AssistantRuntimeBackend.allCases {
                let installSupport = self.installSupport
                group.addTask {
                    let guidance = await installSupport.inspect(backend: backend)
                    return (backend, guidance)
                }
            }

            for await (backend, guidance) in group {
                catalog[backend] = guidance
            }
        }

        installGuidanceByBackend = catalog
        return catalog
    }

    func refreshSessions(limit: Int = 40) async {
        guard !isRefreshingSessions else { return }

        isRefreshingSessions = true
        defer { isRefreshingSessions = false }
        let effectiveLimit = Self.effectiveSessionRefreshLimit(
            requestedLimit: limit,
            visibleLimit: visibleSessionsLimit
        )
        reloadProjectsFromStore()
        reloadTemporarySessionsFromStore()

        if !didPurgeTemporarySessionsOnStartup {
            didPurgeTemporarySessionsOnStartup = true
            await purgeStoredTemporarySessionsOnLaunch()
            reloadProjectsFromStore()
            reloadTemporarySessionsFromStore()
            Task { [weak self] in
                await self?.pruneOrphanedCheckpointArtifacts()
            }
        }

        await purgeExpiredArchivedSessionsIfNeeded()

        let trackedSessionIDs = trackedSidebarSessionIDs()
        let projectLinkedSessionIDs = trackedProjectLinkedSessionIDs()
        do {
            let capturedSelectedSessionID = selectedSessionID
            let managedSessionIDs = Set(trackedSessionIDs.compactMap { normalizedSessionID($0) })

            async let catalogSessionsTask = loadCatalogSessions(
                limit: effectiveLimit,
                trackedSessionIDs: trackedSessionIDs,
                preferredSessionID: capturedSelectedSessionID
            )
            async let openAssistSessionsTask = loadOpenAssistSessions(
                managedSessionIDs: managedSessionIDs
            )
            async let copilotSessionsTask = loadManagedCopilotSessions(
                limit: effectiveLimit,
                managedSessionIDs: managedSessionIDs
            )

            let catalogSessions = try await catalogSessionsTask
            let openAssistSessions = await openAssistSessionsTask
            let copilotSessions = await copilotSessionsTask
            let knownSessionIDs = Set(
                (catalogSessions + openAssistSessions + copilotSessions).compactMap { normalizedSessionID($0.id) }
            )
            let recoveredProjectSessions = recoverProjectLinkedOpenAssistSessions(
                projectLinkedSessionIDs: projectLinkedSessionIDs,
                excluding: knownSessionIDs
            )
            // Run conversation-store directory scan on a background thread to
            // avoid blocking the main thread with snapshot reads during session
            // list refreshes.
            let capturedKnownSessionIDs = knownSessionIDs
                .union(recoveredProjectSessions.compactMap { normalizedSessionID($0.id) })
            let recoveredConversationStoreSessions = await loadConversationStoreSessionsInBackground(
                excluding: capturedKnownSessionIDs
            )
            var merged = deduplicateSessions(
                catalogSessions
                    + openAssistSessions
                    + copilotSessions
                    + recoveredProjectSessions
                    + recoveredConversationStoreSessions
            )
            let persistedSessionIDs = Set(merged.compactMap { normalizedSessionID($0.id) })
            reconcilePendingFreshSessions(with: persistedSessionIDs)
            merged = mergePendingFreshSessions(into: merged)
            merged = sortSessionsByRecency(deduplicateSessions(merged))

            if let currentSelectedSessionID = selectedSessionID?.nonEmpty,
               !merged.contains(where: { sessionsMatch($0.id, currentSelectedSessionID) }) {
                if let existingSelected = sessions.first(where: { sessionsMatch($0.id, currentSelectedSessionID) }) {
                    merged.removeAll {
                        sessionMatchesIdentity(
                            $0,
                            sessionID: existingSelected.id,
                            source: existingSelected.source
                        )
                    }
                    merged.insert(existingSelected, at: 0)
                }
            }

            withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
                sessions = retainedProjectLinkedSessions(
                    from: merged,
                    limit: effectiveLimit,
                    pinnedSessionIDs: projectLinkedSessionIDs
                )
            }
            persistManagedSessionsSnapshot()
            ensureSessionVisible(selectedSessionID)

            if let currentSelectedSession = sessions.first(where: { sessionsMatch($0.id, selectedSessionID) }),
               !assistantSessionSupportsCurrentThreadUI(currentSelectedSession) {
                self.selectedSessionID = nil
                transcriptSessionID = nil
                timelineSessionID = nil
                timelineItems = []
                clearActiveProposedPlanIfNeeded(for: nil)
            }

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

            restoreVisibleProviderState(for: selectedSession)
            refreshMemoryState(for: selectedSessionID)
            reloadMemoryInspectorSnapshot(closeIfMissing: true)
            scheduleSelectedSessionHistoryReload(force: transcript.isEmpty || timelineItems.isEmpty)
            if selectedSessionID == nil {
                cancelSelectedSessionWarmup()
            } else {
                scheduleSelectedSessionWarmupIfNeeded()
            }
            scheduleProjectMemoryCatchUp()
        } catch {
            lastStatusMessage = error.localizedDescription
        }
    }

    private func loadOpenAssistSessions(
        managedSessionIDs: Set<String>
    ) async -> [AssistantSessionSummary] {
        let filteredSessionIDs = managedSessionIDs.isEmpty ? nil : managedSessionIDs
        return filterRestorableSessions(
            applyStoredSessionMetadata(
                to: sessionRegistry.sessions(
                    sources: Set([.openAssist]),
                    sessionIDs: filteredSessionIDs
                )
            )
        )
    }

    private func trackedSidebarSessionIDs() -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()

        for candidate in resolvedOwnedSessionIDs() {
            guard let normalizedCandidate = normalizedSessionID(candidate),
                  seen.insert(normalizedCandidate).inserted else {
                continue
            }
            ordered.append(candidate)
        }

        for candidate in projectStore.snapshot().threadAssignments.keys.sorted() {
            guard let normalizedCandidate = normalizedSessionID(candidate),
                  seen.insert(normalizedCandidate).inserted else {
                continue
            }
            ordered.append(candidate)
        }

        return ordered
    }

    private func trackedProjectLinkedSessionIDs() -> Set<String> {
        Set(
            projectStore.snapshot().threadAssignments.keys.compactMap { candidate in
                guard let normalizedCandidate = normalizedSessionID(candidate),
                      !deletedSessionIDs.contains(normalizedCandidate) else {
                    return nil
                }
                return normalizedCandidate
            }
        )
    }

    private func recoverProjectLinkedOpenAssistSessions(
        projectLinkedSessionIDs: Set<String>,
        excluding knownSessionIDs: Set<String>
    ) -> [AssistantSessionSummary] {
        guard !projectLinkedSessionIDs.isEmpty else { return [] }

        return projectLinkedSessionIDs.compactMap { sessionID in
            guard !knownSessionIDs.contains(sessionID) else {
                return nil
            }
            return loadConversationStoreSessionSummary(threadID: sessionID)
        }
    }

    private func recoverConversationStoreOpenAssistSessions(
        excluding knownSessionIDs: Set<String>
    ) -> [AssistantSessionSummary] {
        let savedThreads = conversationStore.savedConversationThreads(includeNotesOnly: false)
        guard !savedThreads.isEmpty else { return [] }

        return savedThreads.compactMap { threadSummary in
            guard let normalizedThreadID = normalizedSessionID(threadSummary.threadID),
                  !knownSessionIDs.contains(normalizedThreadID),
                  !deletedSessionIDs.contains(normalizedThreadID),
                  threadSummary.hasConversationContent else {
                return nil
            }

            return conversationStoreSessionSummary(from: threadSummary)
        }
    }

    /// Loads conversation-store sessions on a background thread so the
    /// directory scan and snapshot reads don't block the main thread.
    private func loadConversationStoreSessionsInBackground(
        excluding knownSessionIDs: Set<String>
    ) async -> [AssistantSessionSummary] {
        let store = conversationStore
        let capturedDeletedSessionIDs = deletedSessionIDs
        return await withCheckedContinuation { continuation in
            Self.conversationReadQueue.async {
                let savedThreads = store.savedConversationThreads(includeNotesOnly: false)
                guard !savedThreads.isEmpty else {
                    continuation.resume(returning: [])
                    return
                }
                let sessions = savedThreads.compactMap { threadSummary -> AssistantSessionSummary? in
                    let normalizedThreadID = threadSummary.threadID
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    guard !normalizedThreadID.isEmpty,
                          !knownSessionIDs.contains(normalizedThreadID),
                          !capturedDeletedSessionIDs.contains(normalizedThreadID),
                          threadSummary.hasConversationContent else {
                        return nil
                    }
                    let latestUserMessage = threadSummary.latestUserMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let latestAssistantMessage = threadSummary.latestAssistantMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let selectedNoteTitle = threadSummary.noteTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let preferredTitle = latestUserMessage ?? selectedNoteTitle ?? latestAssistantMessage ?? "Saved Open Assist Chat"
                    let collapsedTitle = preferredTitle
                        .replacingOccurrences(of: "\r\n", with: "\n")
                        .components(separatedBy: .whitespacesAndNewlines)
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                    let title = collapsedTitle.isEmpty ? "Saved Open Assist Chat"
                        : (collapsedTitle.count > 84 ? String(collapsedTitle.prefix(83)).trimmingCharacters(in: .whitespacesAndNewlines) + "\u{2026}" : collapsedTitle)
                    return AssistantSessionSummary(
                        id: normalizedThreadID,
                        title: title,
                        source: .openAssist,
                        threadArchitectureVersion: .providerIndependentV2,
                        conversationPersistence: .hybridJSONL,
                        status: .idle,
                        createdAt: threadSummary.lastUpdatedAt,
                        updatedAt: threadSummary.lastUpdatedAt,
                        summary: latestAssistantMessage ?? latestUserMessage ?? selectedNoteTitle,
                        latestUserMessage: latestUserMessage,
                        latestAssistantMessage: latestAssistantMessage
                    )
                }
                continuation.resume(returning: sessions)
            }
        }
    }

    private func loadConversationStoreSessionSummary(threadID: String) -> AssistantSessionSummary? {
        guard let normalizedThreadID = normalizedSessionID(threadID) else {
            return nil
        }

        let notesWorkspace = conversationStore.loadThreadNotesWorkspace(threadID: normalizedThreadID)
        let snapshot = conversationStore.loadSnapshot(threadID: normalizedThreadID)
        guard let snapshot = snapshot ?? notesWorkspace.selectedNote.map({ _ in
            AssistantConversationSnapshot.empty(threadID: normalizedThreadID)
        }) else {
            return nil
        }

        let latestUserMessage = snapshot.transcript.reversed().first(where: { $0.role == .user })?.text.assistantNonEmpty
        let latestAssistantMessage = snapshot.transcript.reversed().first(where: { $0.role == .assistant })?.text.assistantNonEmpty
        let selectedNoteTitle = notesWorkspace.selectedNote?.title.assistantNonEmpty
        let createdAt = snapshot.transcript.first?.createdAt
            ?? snapshot.timeline.first?.createdAt
            ?? snapshot.turns.compactMap(\.createdAt).min()
            ?? notesWorkspace.notes.map(\.createdAt).min()
            ?? snapshot.updatedAt
        let updatedAt = max(
            snapshot.updatedAt,
            notesWorkspace.notes.map(\.updatedAt).max() ?? snapshot.updatedAt
        )

        return AssistantSessionSummary(
            id: normalizedThreadID,
            title: conversationStoreSessionTitle(
                latestUserMessage: latestUserMessage,
                latestAssistantMessage: latestAssistantMessage,
                selectedNoteTitle: selectedNoteTitle
            ),
            source: .openAssist,
            threadArchitectureVersion: .providerIndependentV2,
            conversationPersistence: .hybridJSONL,
            status: .idle,
            createdAt: createdAt,
            updatedAt: updatedAt,
            summary: latestAssistantMessage ?? latestUserMessage ?? selectedNoteTitle,
            latestUserMessage: latestUserMessage,
            latestAssistantMessage: latestAssistantMessage
        )
    }

    private func conversationStoreSessionSummary(
        from threadSummary: AssistantConversationThreadSummary
    ) -> AssistantSessionSummary? {
        guard let normalizedThreadID = normalizedSessionID(threadSummary.threadID) else {
            return nil
        }

        let latestUserMessage = threadSummary.latestUserMessage?.assistantNonEmpty
        let latestAssistantMessage = threadSummary.latestAssistantMessage?.assistantNonEmpty
        let selectedNoteTitle = threadSummary.noteTitle?.assistantNonEmpty

        return AssistantSessionSummary(
            id: normalizedThreadID,
            title: conversationStoreSessionTitle(
                latestUserMessage: latestUserMessage,
                latestAssistantMessage: latestAssistantMessage,
                selectedNoteTitle: selectedNoteTitle
            ),
            source: .openAssist,
            threadArchitectureVersion: .providerIndependentV2,
            conversationPersistence: .hybridJSONL,
            status: .idle,
            createdAt: threadSummary.lastUpdatedAt,
            updatedAt: threadSummary.lastUpdatedAt,
            summary: latestAssistantMessage ?? latestUserMessage ?? selectedNoteTitle,
            latestUserMessage: latestUserMessage,
            latestAssistantMessage: latestAssistantMessage
        )
    }

    private func conversationStoreSessionTitle(
        latestUserMessage: String?,
        latestAssistantMessage: String?,
        selectedNoteTitle: String?
    ) -> String {
        let preferredTitle = latestUserMessage?.assistantNonEmpty
            ?? selectedNoteTitle?.assistantNonEmpty
            ?? latestAssistantMessage?.assistantNonEmpty
            ?? "Saved Open Assist Chat"
        let collapsedTitle = preferredTitle
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let normalizedTitle = collapsedTitle.assistantNonEmpty ?? "Saved Open Assist Chat"
        guard normalizedTitle.count > 84 else {
            return normalizedTitle
        }
        return String(normalizedTitle.prefix(83)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private func retainedProjectLinkedSessions(
        from sessions: [AssistantSessionSummary],
        limit: Int,
        pinnedSessionIDs: Set<String>
    ) -> [AssistantSessionSummary] {
        var retained = Array(sessions.prefix(limit))
        guard !pinnedSessionIDs.isEmpty else {
            return retained
        }

        let retainedIDs = Set(retained.compactMap { normalizedSessionID($0.id) })
        let missingPinnedSessions = sessions.filter { session in
            guard let normalizedID = normalizedSessionID(session.id) else {
                return false
            }
            return pinnedSessionIDs.contains(normalizedID) && !retainedIDs.contains(normalizedID)
        }

        guard !missingPinnedSessions.isEmpty else {
            return retained
        }

        retained.append(contentsOf: missingPinnedSessions)
        return sortSessionsByRecency(deduplicateSessions(retained))
    }

    private func loadCatalogSessions(
        limit: Int,
        trackedSessionIDs: [String],
        preferredSessionID: String?
    ) async throws -> [AssistantSessionSummary] {
        async let byIDTask: [AssistantSessionSummary] = trackedSessionIDs.isEmpty
            ? []
            : sessionCatalog.loadSessions(
                limit: max(limit, trackedSessionIDs.count),
                preferredThreadID: preferredSessionID,
                preferredCWD: nil,
                sessionIDs: trackedSessionIDs
            )
        async let byOriginatorTask: [AssistantSessionSummary] = sessionCatalog.loadSessions(
            limit: limit,
            preferredThreadID: preferredSessionID,
            preferredCWD: nil,
            originatorFilter: "Open Assist"
        )
        let (byID, byOriginator) = try await (byIDTask, byOriginatorTask)
        var merged: [AssistantSessionSummary] = byID
        let existingIDs = Set(byID.map { $0.id.lowercased() })
        for session in byOriginator where !existingIDs.contains(session.id.lowercased()) {
            merged.append(session)
        }
        let filteredSessions = filterRestorableSessions(applyStoredSessionMetadata(to: merged))
        for session in filteredSessions
        where session.parentThreadID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty == nil {
            recordOwnedSessionID(session.id)
        }
        return filteredSessions
    }

    private func loadManagedCopilotSessions(
        limit: Int,
        managedSessionIDs: Set<String>
    ) async -> [AssistantSessionSummary] {
        guard !managedSessionIDs.isEmpty else { return [] }

        let storedSessions = applyStoredSessionMetadata(to: sessionRegistry.sessions(
            sources: Set([.cli]),
            sessionIDs: managedSessionIDs
        ))
        let filteredStoredSessions = filterRestorableSessions(storedSessions)

        guard assistantBackend == .copilot else {
            return filteredStoredSessions
        }

        let inspectionLimit = max(limit * 8, managedSessionIDs.count + temporarySessionIDs.count + 40)

        do {
            if rootRuntime.backend != .copilot {
                await rootRuntime.stop()
                rootRuntime.clearCachedEnvironmentState()
                rootRuntime.backend = .copilot
            }

            let liveSessions = try await rootRuntime.listSessions(limit: inspectionLimit).filter { session in
                guard let normalizedSessionID = normalizedSessionID(session.id) else {
                    return false
                }
                return managedSessionIDs.contains(normalizedSessionID)
            }
            return deduplicateSessions(
                filterRestorableSessions(
                    applyStoredSessionMetadata(to: liveSessions + filteredStoredSessions)
                )
            )
        } catch {
            lastStatusMessage = error.localizedDescription
            return filteredStoredSessions
        }
    }

    private func persistManagedSessionsSnapshot() {
        let managedSessionIDs = Set(trackedSidebarSessionIDs().compactMap { normalizedSessionID($0) })
        let managedSessions = sessions.filter { session in
            guard let normalizedID = normalizedSessionID(session.id) else {
                return false
            }
            return managedSessionIDs.contains(normalizedID)
                && (session.source == .cli || session.source == .openAssist)
                && session.conversationPersistence.persistsConversationHistory
        }

        do {
            try sessionRegistry.replaceSessions(managedSessions, for: Set([.cli, .openAssist]))
        } catch {
            CrashReporter.logWarning("Assistant session registry save failed: \(error.localizedDescription)")
        }
    }

    func refreshAll() {
        Task { @MainActor in
            await refreshEnvironment()
            await refreshSessions()
            refreshSkills()
            refreshMemoryState(for: selectedSessionID)
        }
    }

    var canAttachSkillsToSelectedThread: Bool {
        selectedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty != nil
    }

    func skills(in group: AssistantSkillLibraryGroup) -> [AssistantSkillDescriptor] {
        availableSkills.filter { $0.libraryGroup == group }
    }

    func isSkillAttachedToSelectedThread(_ skill: AssistantSkillDescriptor) -> Bool {
        activeThreadSkills.contains { $0.skillName == skill.name }
    }

    func refreshSkills() {
        availableSkills = skillScanService.scan()
        if availableSkills.isEmpty {
            refreshActiveThreadSkills(syncRuntime: true)
        }
    }

    func attachSkill(_ skill: AssistantSkillDescriptor, to threadID: String? = nil) {
        guard let resolvedThreadID = (threadID ?? selectedSessionID)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty else {
            lastStatusMessage = "Open a thread first, then attach a skill."
            return
        }

        do {
            try threadSkillStore.attach(skillName: skill.name, to: resolvedThreadID)
            refreshActiveThreadSkills(syncRuntime: true)
            lastStatusMessage = "Attached “\(skill.displayName)” to this thread."
        } catch {
            lastStatusMessage = error.localizedDescription
        }
    }

    func detachSkill(_ skillName: String, from threadID: String? = nil) {
        guard let resolvedThreadID = (threadID ?? selectedSessionID)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty else {
            lastStatusMessage = "Open a thread first, then remove a skill."
            return
        }

        do {
            try threadSkillStore.detach(skillName: skillName, from: resolvedThreadID)
            refreshActiveThreadSkills(syncRuntime: true)
            lastStatusMessage = "Removed “\(assistantSkillDisplayName(fromIdentifier: skillName))” from this thread."
        } catch {
            lastStatusMessage = error.localizedDescription
        }
    }

    func importSkill(
        fromFolderURL folderURL: URL,
        attachToCurrentThread: Bool = true
    ) {
        do {
            let skill = try skillImportService.importSkill(fromFolderURL: folderURL)
            refreshSkills()
            if attachToCurrentThread && canAttachSkillsToSelectedThread {
                attachSkill(skill)
            } else {
                lastStatusMessage = "Imported “\(skill.displayName)”. Attach it to a thread when you need it."
            }
        } catch {
            lastStatusMessage = error.localizedDescription
        }
    }

    func importSkill(
        fromGitHubReference reference: String,
        attachToCurrentThread: Bool = true
    ) async {
        do {
            let skill = try await skillImportService.importSkill(fromGitHubReference: reference)
            refreshSkills()
            if attachToCurrentThread && canAttachSkillsToSelectedThread {
                attachSkill(skill)
            } else {
                lastStatusMessage = "Imported “\(skill.displayName)”. Attach it to a thread when you need it."
            }
        } catch {
            lastStatusMessage = error.localizedDescription
        }
    }

    func createSkill(
        from draft: AssistantSkillWizardDraft,
        attachToCurrentThread: Bool = true
    ) {
        do {
            let skill = try skillWizardService.createSkill(from: draft)
            refreshSkills()
            if attachToCurrentThread && canAttachSkillsToSelectedThread {
                attachSkill(skill)
            } else {
                lastStatusMessage = "Created “\(skill.displayName)”. Attach it to a thread when you need it."
            }
        } catch {
            lastStatusMessage = error.localizedDescription
        }
    }

    func duplicateSkill(_ skill: AssistantSkillDescriptor, attachToCurrentThread: Bool = false) {
        do {
            let duplicatedSkill = try skillImportService.duplicateSkill(skill)
            refreshSkills()
            if attachToCurrentThread && canAttachSkillsToSelectedThread {
                attachSkill(duplicatedSkill)
            } else {
                lastStatusMessage = "Duplicated “\(skill.displayName)” as “\(duplicatedSkill.displayName)”."
            }
        } catch {
            lastStatusMessage = error.localizedDescription
        }
    }

    func deleteSkill(_ skill: AssistantSkillDescriptor) {
        do {
            try skillImportService.deleteSkill(skill)
            refreshSkills()
            lastStatusMessage = "Deleted “\(skill.displayName)”. Any old thread binding will now show as missing."
        } catch {
            lastStatusMessage = error.localizedDescription
        }
    }

    func revealSkill(_ skill: AssistantSkillDescriptor) {
        NSWorkspace.shared.activateFileViewerSelecting([skill.skillDirectoryURL])
    }

    func repairMissingSkillBindings() {
        let previousMissingCount = activeThreadSkills.filter(\.isMissing).count
        refreshSkills()
        let remainingMissingCount = activeThreadSkills.filter(\.isMissing).count

        if previousMissingCount > 0 && remainingMissingCount == 0 {
            lastStatusMessage = "Repaired the missing skill bindings for this thread."
        } else if remainingMissingCount > 0 {
            lastStatusMessage = "Some skills are still missing. Restore or re-import them, or remove the binding."
        } else {
            lastStatusMessage = "This thread does not have any missing skills."
        }
    }

    func remoteSessionSnapshot(
        sessionID: String,
        transcriptLimit: Int = 48
    ) async -> AssistantRemoteSessionSnapshot? {
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionID.isEmpty else { return nil }

        let sessionSummary: AssistantSessionSummary?
        if let cachedSession = sessions.first(where: { sessionsMatch($0.id, normalizedSessionID) }) {
            sessionSummary = cachedSession
        } else if let storedSession = applyStoredSessionMetadata(
            to: sessionRegistry.sessions(
                sources: Set([.openAssist, .cli]),
                sessionIDs: Set([normalizedSessionID.lowercased()])
            )
        ).first {
            sessionSummary = storedSession
        } else {
            let loaded = try? await sessionCatalog.loadSessions(
                limit: 1,
                preferredThreadID: normalizedSessionID,
                preferredCWD: nil,
                sessionIDs: [normalizedSessionID]
            )
            sessionSummary = loaded?.first.flatMap { session in
                applyStoredSessionMetadata(to: [session]).first
            }
        }

        guard let session = sessionSummary else { return nil }

        let transcriptEntries: [AssistantTranscriptEntry]
        if sessionsMatch(transcriptSessionID, normalizedSessionID) {
            transcriptEntries = Array(transcript.suffix(transcriptLimit))
        } else {
            let cachedEntries = transcriptEntriesBySessionID[normalizedSessionID] ?? []
            let persistedEntries = await loadPersistedTranscript(
                sessionID: normalizedSessionID,
                limit: transcriptLimit
            )

            if cachedEntries.isEmpty {
                transcriptEntries = persistedEntries
            } else if persistedEntries.isEmpty {
                transcriptEntries = Array(cachedEntries.suffix(transcriptLimit))
            } else {
                transcriptEntries = Array(
                    mergeTranscriptHistory(cachedEntries, with: persistedEntries)
                        .suffix(transcriptLimit)
                )
            }
        }

        let activitySnapshot = sessionActivitySnapshot(for: normalizedSessionID)
        let toolState = sessionExecutionStateBySessionID[normalizedSessionID] ?? AssistantSessionExecutionState()
        let imageDelivery = await latestRemoteImageDelivery(
            for: normalizedSessionID,
            sessionTitle: session.title
        )
        return AssistantRemoteSessionSnapshot(
            session: session,
            transcriptEntries: transcriptEntries,
            pendingPermissionRequest: activitySnapshot.pendingPermissionRequest,
            latestRemoteAttentionEvent: activitySnapshot.latestRemoteAttentionEvent,
            hudState: activitySnapshot.hudState,
            hasActiveTurn: activitySnapshot.hasActiveTurn,
            toolCalls: toolState.toolCalls,
            recentToolCalls: toolState.recentToolCalls,
            imageDelivery: imageDelivery,
            activeTurnID: activitySnapshot.currentTurnID,
            pendingOutgoingMessage: activitySnapshot.pendingOutgoingMessage,
            awaitingAssistantStart: activitySnapshot.awaitingAssistantStart,
            queuedPromptCount: activitySnapshot.queuedPromptCount
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

        guard let imageItem = latestRemoteImageItem(in: timelineItems) else {
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

        // Include the timeline item's ID in the signature so each observation is
        // unique even if the screen pixels haven't changed. This prevents skipping
        // delivery when the user explicitly asks to see the current screen again.
        let signatureSeed = "\(imageItem.id)|\(attachments.map(\.id).joined(separator: "|"))"
        return AssistantRemoteImageDelivery(
            signature: MemoryIdentifier.stableHexDigest(for: signatureSeed),
            caption: caption,
            attachments: attachments
        )
    }

    func latestRemoteImageItem(in timelineItems: [AssistantTimelineItem]) -> AssistantTimelineItem? {
        let currentTurnItems: ArraySlice<AssistantTimelineItem>
        if let lastUserIndex = timelineItems.lastIndex(where: { $0.kind == .userMessage }) {
            let nextIndex = timelineItems.index(after: lastUserIndex)
            currentTurnItems = timelineItems[nextIndex...]
        } else {
            currentTurnItems = timelineItems[...]
        }

        // Only return images from the current turn. Don't fall back to the full
        // timeline — that re-delivers stale screenshots from previous turns and
        // causes duplicates on Telegram.
        return currentTurnItems.reversed().first(where: Self.isRemoteImageTimelineItem)
    }

    private static func isRemoteImageTimelineItem(_ item: AssistantTimelineItem) -> Bool {
        guard let images = item.imageAttachments, !images.isEmpty else {
            return false
        }
        switch item.kind {
        case .userMessage:
            return false
        case .assistantProgress, .assistantFinal, .activity, .permission, .plan, .system:
            return true
        }
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
        if selectedSession?.isProviderIndependentThreadV2 != true {
            settings.assistantPreferredModelID = trimmed
        }
        applyRuntimeModelSelection(trimmed, force: true)
    }

    func chooseSubagentModel(_ modelID: String?) {
        let trimmed = modelID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        settings.assistantPreferredSubagentModelID = trimmed ?? ""
        applyRuntimeSubagentModelSelection(trimmed, force: true)
    }

    func applyRuntimeModelSelection(_ modelID: String?, force: Bool = false) {
        let trimmed = modelID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        guard let trimmed else {
            selectedModelID = nil
            runtime.setPreferredModelID(nil)
            runtimeHealth.selectedModelID = nil
            syncRuntimeContext()
            return
        }

        if !force, !visibleModels.contains(where: { $0.id == trimmed }) {
            return
        }

        selectedModelID = trimmed
        syncReasoningEffortWithSelectedModel(preferModelDefault: true)
        runtime.setPreferredModelID(trimmed)
        runtimeHealth.selectedModelID = trimmed
        if visibleAssistantBackend == .ollamaLocal,
           let selectedModel = visibleModels.first(where: { $0.id == trimmed }) {
            runtimeHealth.availability = selectedModel.isInstalled ? .ready : .installRequired
            runtimeHealth.summary = selectedModel.isInstalled
                ? visibleAssistantBackend.connectedSummary
                : visibleAssistantBackend.missingInstallSummary
            runtimeHealth.detail = selectedModel.isInstalled
                ? nil
                : "\(selectedModel.displayName) is not installed yet. Open Setup to download it, or choose an installed local model."
        }
        syncRuntimeContext()
    }

    func applyRuntimeSubagentModelSelection(_ modelID: String?, force: Bool = false) {
        let trimmed = modelID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        if let trimmed, !force, !visibleModels.contains(where: { $0.id == trimmed }) {
            return
        }
        if let trimmed, force, !visibleModels.contains(where: { $0.id == trimmed }) {
            return
        }

        selectedSubagentModelID = trimmed
        runtime.setPreferredSubagentModelID(trimmed)
        syncRuntimeContext()
    }

    func selectionSideAssistantVisibleModels(
        for backend: AssistantRuntimeBackend
    ) -> [AssistantModelOption] {
        Self.selectableModels(
            for: backend,
            from: cachedAvailableModels(threadID: selectedSessionID, backend: backend)
        )
    }

    func selectionSideAssistantResolvedModelID(
        for backend: AssistantRuntimeBackend,
        preferredModelID: String?
    ) -> String? {
        let models = cachedAvailableModels(threadID: selectedSessionID, backend: backend)
        return Self.resolvedModelSelection(
            from: nil,
            backend: backend,
            availableModels: models,
            preferredModelID: preferredModelID,
            surfaceModelID: nil
        )
    }

    func loadSelectionSideAssistantVisibleModels(
        for backend: AssistantRuntimeBackend
    ) async -> [AssistantModelOption] {
        let cachedModels = selectionSideAssistantVisibleModels(for: backend)
        if !cachedModels.isEmpty {
            return cachedModels
        }

        let guidance = await installSupport.inspect(backend: backend)
        guard guidance.codexDetected else {
            return []
        }

        let warmRuntime = runtimeFactory()
        warmRuntime.backend = backend

        do {
            let details = try await warmRuntime.refreshEnvironment(codexPath: guidance.codexPath)
            if !details.models.isEmpty {
                providerAvailableModelsByBackend[backend] = details.models
            }
        } catch {
            await warmRuntime.stop()
            return selectionSideAssistantVisibleModels(for: backend)
        }

        await warmRuntime.stop()
        return selectionSideAssistantVisibleModels(for: backend)
    }

    func startAccountLogin() {
        Task { @MainActor in
            let backend = self.assistantBackend
            guard backend.requiresLogin else {
                self.runPreferredInstallCommand(for: backend)
                return
            }
            if accountSnapshot.isLoggedIn {
                self.lastStatusMessage = backend.alreadySignedInMessage
                self.runtimeHealth = AssistantRuntimeHealth(
                    availability: .ready,
                    summary: backend.connectedSummary,
                    detail: nil,
                    runtimePath: runtimeHealth.runtimePath,
                    selectedModelID: selectedModelID,
                    accountEmail: accountSnapshot.email,
                    accountPlan: accountSnapshot.planType
                )
                return
            }

            do {
                switch try await runtime.startLogin() {
                case .openURL(let loginURL):
                    NSWorkspace.shared.open(loginURL)
                case .runCommand(let command):
                    runInTerminal(command)
                case .none:
                    await refreshEnvironment(permissions: permissions)
                }
            } catch {
                self.lastStatusMessage = error.localizedDescription
            }
        }
    }

    func startNewSession(cwd: String? = nil) async {
        await startSession(cwd: cwd, isTemporary: false)
    }

    func startNewTemporarySession(cwd: String? = nil) async {
        await startSession(cwd: cwd, isTemporary: true)
    }

    private static func makeOpenAssistThreadID() -> String {
        "openassist-\(UUID().uuidString.lowercased())"
    }

    private func resetVisibleConversationStateForNewThread() {
        setVisibleTimeline([], for: nil)
        transcript = []
        transcriptSessionID = nil
        planEntries = []
        toolCalls = []
        recentToolCalls = []
        pendingPermissionRequest = nil
        lastSubmittedPrompt = nil
        taskMode = .chat
        sessionInstructions = ""
        oneShotSessionInstructions = nil
        proposedPlan = nil
        proposedPlanSessionID = nil
        tokenUsage = .empty
        subagents = []
        notesWorkspaceRuntimeContext = nil
        syncRuntimeContext()
    }

    @discardableResult
    private func createOpenAssistThread(cwd: String? = nil, isTemporary: Bool) -> String {
        let sessionID = Self.makeOpenAssistThreadID()
        deletedSessionIDs.remove(sessionID.lowercased())
        let requestedCWD = cwd ?? selectedProjectLinkedFolderPathIfUsable()
        let targetProjectID = selectedProject?.id
        let now = Date()
        let thread = AssistantSessionSummary(
            id: sessionID,
            title: "New Assistant Session",
            source: .openAssist,
            threadArchitectureVersion: .providerIndependentV2,
            conversationPersistence: isTemporary ? .transient : .hybridJSONL,
            providerBackend: nil,
            providerSessionID: nil,
            activeProvider: nil,
            providerBindingsByBackend: [],
            status: .idle,
            cwd: requestedCWD,
            effectiveCWD: requestedCWD,
            createdAt: now,
            updatedAt: now,
            summary: nil,
            latestModel: selectedModelID,
            latestTaskMode: taskMode,
            latestInteractionMode: interactionMode,
            latestReasoningEffort: reasoningEffort,
            latestServiceTier: fastModeEnabled ? "fast" : nil,
            latestUserMessage: nil,
            latestAssistantMessage: nil,
            isTemporary: isTemporary,
            projectID: targetProjectID,
            projectName: selectedProject?.name,
            linkedProjectFolderPath: requestedCWD
        )

        if !isTemporary {
            recordOwnedSessionID(sessionID)
        }
        if let targetProjectID {
            try? updateSessionProjectAssignment(sessionID: sessionID, projectID: targetProjectID)
        }
        setTemporaryFlag(isTemporary, for: sessionID, reportErrors: true)
        if settings.assistantMemoryEnabled && !isTemporary {
            _ = try? threadMemoryService.ensureMemoryFile(for: sessionID)
        }

        sessions.removeAll { sessionsMatch($0.id, sessionID) }
        sessions.insert(thread, at: 0)
        persistManagedSessionsSnapshot()
        return sessionID
    }

    private func ensureVisibleSessionForPendingPrompt() -> String {
        if let selectedSessionID = selectedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            return selectedSessionID
        }

        let sessionID = createOpenAssistThread(isTemporary: false)
        selectedSessionID = sessionID
        transcriptSessionID = sessionID
        timelineSessionID = sessionID
        ensureSessionVisible(sessionID)
        refreshMemoryState(for: sessionID)
        return sessionID
    }

    private func startSession(cwd: String? = nil, isTemporary: Bool) async {
        guard canCreateThread else {
            lastStatusMessage = "Finish the current undo or edit before starting a new thread."
            return
        }
        cancelSelectedSessionWarmup()
        let previousSelectedSessionID = selectedSessionID
        flushPersistedHistoryIfNeeded(sessionID: previousSelectedSessionID)
        resetVisibleConversationStateForNewThread()
        let sessionID = createOpenAssistThread(cwd: cwd, isTemporary: isTemporary)
        selectedSessionID = sessionID
        transcriptSessionID = sessionID
        timelineSessionID = sessionID
        ensureSessionVisible(sessionID)
        refreshMemoryState(for: sessionID)
        await cleanupTemporarySessionAfterLeaving(
            previousSelectedSessionID,
            nextSelectedSessionID: sessionID
        )
        ensureSessionVisible(sessionID)
        if isTemporary {
            lastStatusMessage = "Started a temporary chat."
        }
    }

    /// Resumes an existing Codex thread for a scheduled job, or starts a fresh one if none exists.
    /// Returns the session ID that was activated, or nil on failure.
    func resumeOrStartScheduledJobSession(existingID: String?) async -> String? {
        syncRuntimeContext()
        do {
            if let existingID = existingID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
                let scheduledRuntime = ensureRuntime(for: existingID)
                do {
                    try await scheduledRuntime.resumeSession(
                        existingID,
                        cwd: nil,
                        preferredModelID: selectedModelID
                    )
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
                let scheduledRuntime = makeUnboundRuntime()
                let sessionID = try await scheduledRuntime.startNewSession(
                    cwd: nil,
                    preferredModelID: selectedModelID
                )
                moveRuntimeRegistration(
                    from: sessionIDBoundToRuntime(scheduledRuntime),
                    to: sessionID,
                    runtime: scheduledRuntime
                )
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
        let previousSelectedSessionID = selectedSessionID
        flushPersistedHistoryIfNeeded(sessionID: previousSelectedSessionID)
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
            markPendingFreshSession(sessionID, source: assistantBackend.sessionSource)
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
        await cleanupTemporarySessionAfterLeaving(
            previousSelectedSessionID,
            nextSelectedSessionID: sessionID
        )
        ensureSessionVisible(sessionID)
        return sessionID
    }

    func openSession(_ session: AssistantSessionSummary) async {
        let normalizedSessionID = session.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionID.isEmpty else { return }
        cancelSelectedSessionWarmup()
        guard assistantSessionSupportsCurrentThreadUI(session) else {
            lastStatusMessage = "This older chat is not supported in the new thread view anymore, so Open Assist now hides it from the sidebar."
            return
        }
        let desiredBackend = backend(for: session)
        let sessionRuntime = ensureRuntime(for: normalizedSessionID)

        let previousSelectedSessionID = selectedSessionID
        if !sessionsMatch(previousSelectedSessionID, normalizedSessionID) {
            flushPersistedHistoryIfNeeded(sessionID: previousSelectedSessionID)
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
            restoreVisibleProviderState(for: session)
            await refreshEnvironment(permissions: permissions)
            refreshMemoryState(for: normalizedSessionID)
            refreshEditableTurns(for: normalizedSessionID)
            scheduleSelectedSessionHistoryReload(force: true)
            scheduleSelectedSessionWarmupIfNeeded()
            return
        }

        let requestID = UUID()
        sessionLoadRequestID = requestID
        selectedSessionID = normalizedSessionID
        isTransitioningSession = true
        restoreVisibleProviderState(for: session)
        await Task.yield()

        if sessionRuntime.backend != desiredBackend {
            await sessionRuntime.stop()
            sessionRuntime.clearCachedEnvironmentState()
            sessionRuntime.backend = desiredBackend
        }

        if session.isCanonicalThread {
            await openOpenAssistSession(
                session,
                normalizedSessionID: normalizedSessionID,
                previousSelectedSessionID: previousSelectedSessionID,
                requestID: requestID
            )
            return
        }

        if session.source == .cli {
            await openCopilotSession(
                session,
                normalizedSessionID: normalizedSessionID,
                previousSelectedSessionID: previousSelectedSessionID,
                requestID: requestID
            )
            return
        }

        if hasUsableCachedHistory {
            setVisibleTimeline(cachedTimeline, for: normalizedSessionID)
            setVisibleTranscript(cachedTranscript, for: normalizedSessionID)
            refreshEditableTurns(for: normalizedSessionID)
            refreshMemoryState(for: normalizedSessionID)
        } else {
            setVisibleHistoryLoadingState(for: normalizedSessionID)
        }

        await Task.yield()
        await refreshEnvironment(permissions: permissions)
        scheduleSelectedSessionWarmupIfNeeded()
        if hasUsableCachedHistory {
            isTransitioningSession = false
            await cleanupTemporarySessionAfterLeaving(
                previousSelectedSessionID,
                nextSelectedSessionID: normalizedSessionID
            )
            return
        } else {
            let recentChunk = await loadRecentHistoryChunk(
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
                scheduleSelectedSessionHistoryReload(force: true)
                scheduleSelectedSessionWarmupIfNeeded()
                refreshMemoryState(for: normalizedSessionID)
                isTransitioningSession = false
                await cleanupTemporarySessionAfterLeaving(
                    previousSelectedSessionID,
                    nextSelectedSessionID: normalizedSessionID
                )
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
        scheduleSelectedSessionWarmupIfNeeded()
        isTransitioningSession = false
        await cleanupTemporarySessionAfterLeaving(
            previousSelectedSessionID,
            nextSelectedSessionID: normalizedSessionID
        )
    }

    private func openOpenAssistSession(
        _ session: AssistantSessionSummary,
        normalizedSessionID: String,
        previousSelectedSessionID: String?,
        requestID: UUID
    ) async {
        ensureSessionVisible(normalizedSessionID)
        let cachedTimeline = timelineItemsBySessionID[normalizedSessionID] ?? []
        let cachedTranscript = transcriptEntriesBySessionID[normalizedSessionID] ?? []
        let timelineLimit = currentTimelineHistoryLimit(
            for: normalizedSessionID,
            minimum: Self.HistoryLoading.initialTimelineLimit
        )
        let transcriptLimit = currentTranscriptHistoryLimit(
            for: normalizedSessionID,
            minimum: Self.HistoryLoading.initialTranscriptLimit
        )
        let hasUsableCachedHistory = hasRenderableTimelineHistory(cachedTimeline)

        if hasUsableCachedHistory || !cachedTranscript.isEmpty {
            setVisibleTimeline(cachedTimeline, for: normalizedSessionID)
            setVisibleTranscript(cachedTranscript, for: normalizedSessionID)
            refreshEditableTurns(for: normalizedSessionID)
            refreshMemoryState(for: normalizedSessionID)
        } else {
            setVisibleHistoryLoadingState(for: normalizedSessionID)
        }
        isTransitioningSession = true
        await Task.yield()

        let recentChunk = await loadRecentHistoryChunk(
            sessionID: normalizedSessionID,
            timelineLimit: timelineLimit,
            transcriptLimit: transcriptLimit
        )

        guard sessionLoadRequestID == requestID,
              sessionsMatch(selectedSessionID, normalizedSessionID) else {
            return
        }

        let mergedTimeline = mergeTimelineHistory(recentChunk.timeline, with: cachedTimeline)
        let mergedTranscript = mergeTranscriptHistory(recentChunk.transcript, with: cachedTranscript)

        if !mergedTimeline.isEmpty {
            setVisibleTimeline(mergedTimeline, for: normalizedSessionID)
        } else {
            setVisibleTimeline(cachedTimeline, for: normalizedSessionID)
        }
        setVisibleTranscript(mergedTranscript.isEmpty ? cachedTranscript : mergedTranscript, for: normalizedSessionID)
        canLoadMoreHistoryBySessionID[normalizedSessionID] = recentChunk.hasMore
        refreshEditableTurns(for: normalizedSessionID)
        refreshMemoryState(for: normalizedSessionID)
        restoreVisibleProviderState(for: session)
        let sessionRuntime = ensureRuntime(for: session.id)
        let desiredBackend = backend(for: session)
        _ = await silentlyResumeStoredProviderSession(
            using: sessionRuntime,
            session: session,
            backend: desiredBackend,
            suppressErrors: false
        )

        await refreshEnvironment(permissions: permissions)
        scheduleSelectedSessionHistoryReload(force: true)
        scheduleSelectedSessionWarmupIfNeeded()
        isTransitioningSession = false
        await cleanupTemporarySessionAfterLeaving(
            previousSelectedSessionID,
            nextSelectedSessionID: normalizedSessionID
        )
    }

    private func openCopilotSession(
        _ session: AssistantSessionSummary,
        normalizedSessionID: String,
        previousSelectedSessionID: String?,
        requestID: UUID
    ) async {
        ensureSessionVisible(normalizedSessionID)
        let cachedTimeline = timelineItemsBySessionID[normalizedSessionID] ?? []
        let cachedTranscript = transcriptEntriesBySessionID[normalizedSessionID] ?? []
        let timelineLimit = currentTimelineHistoryLimit(
            for: normalizedSessionID,
            minimum: Self.HistoryLoading.initialTimelineLimit
        )
        let transcriptLimit = currentTranscriptHistoryLimit(
            for: normalizedSessionID,
            minimum: Self.HistoryLoading.initialTranscriptLimit
        )
        let hasUsableCachedHistory = hasRenderableTimelineHistory(cachedTimeline)

        if hasUsableCachedHistory || !cachedTranscript.isEmpty {
            setVisibleTimeline(cachedTimeline, for: normalizedSessionID)
            setVisibleTranscript(cachedTranscript, for: normalizedSessionID)
            refreshEditableTurns(for: normalizedSessionID)
            refreshMemoryState(for: normalizedSessionID)
        } else {
            setVisibleHistoryLoadingState(for: normalizedSessionID)
        }
        isTransitioningSession = true
        await Task.yield()

        let recentChunk = await loadRecentHistoryChunk(
            sessionID: normalizedSessionID,
            timelineLimit: timelineLimit,
            transcriptLimit: transcriptLimit
        )

        guard sessionLoadRequestID == requestID,
              sessionsMatch(selectedSessionID, normalizedSessionID) else {
            return
        }

        let mergedTimeline = mergeTimelineHistory(recentChunk.timeline, with: cachedTimeline)
        let mergedTranscript = mergeTranscriptHistory(recentChunk.transcript, with: cachedTranscript)

        if !mergedTimeline.isEmpty {
            setVisibleTimeline(mergedTimeline, for: normalizedSessionID)
        } else {
            setVisibleTimeline(cachedTimeline, for: normalizedSessionID)
        }
        setVisibleTranscript(mergedTranscript.isEmpty ? cachedTranscript : mergedTranscript, for: normalizedSessionID)
        canLoadMoreHistoryBySessionID[normalizedSessionID] = recentChunk.hasMore
        refreshEditableTurns(for: normalizedSessionID)
        refreshMemoryState(for: normalizedSessionID)
        let sessionRuntime = ensureRuntime(for: session.id)
        _ = await silentlyResumeStoredProviderSession(
            using: sessionRuntime,
            session: session,
            backend: .copilot,
            suppressErrors: false
        )

        await refreshEnvironment(permissions: permissions)
        scheduleSelectedSessionHistoryReload(force: true)
        scheduleSelectedSessionWarmupIfNeeded()
        isTransitioningSession = false
        await cleanupTemporarySessionAfterLeaving(
            previousSelectedSessionID,
            nextSelectedSessionID: normalizedSessionID
        )
    }

    func openSession(threadID: String) async {
        let normalizedThreadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedThreadID.isEmpty else { return }

        if let visibleSession = sessions.first(where: { sessionsMatch($0.id, normalizedThreadID) }) {
            await openSession(visibleSession)
            return
        }

        do {
            let loadedSessions = try await sessionCatalog.loadSessions(
                limit: 1,
                preferredThreadID: normalizedThreadID,
                preferredCWD: nil,
                sessionIDs: [normalizedThreadID]
            )
            guard var loadedSession = loadedSessions.first else {
                lastStatusMessage = "That thread is not available yet."
                return
            }

            loadedSession = applyStoredSessionMetadata(to: [loadedSession]).first ?? loadedSession
            guard let restorableSession = filterRestorableSessions([loadedSession]).first else {
                lastStatusMessage = "That thread is no longer available."
                return
            }
            loadedSession = restorableSession
            if loadedSession.parentThreadID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty == nil {
                recordOwnedSessionID(loadedSession.id)
            }
            if !sessions.contains(where: { sessionsMatch($0.id, loadedSession.id) }) {
                sessions.insert(loadedSession, at: 0)
            }
            ensureSessionVisible(loadedSession.id)
            await openSession(loadedSession)
            return
        } catch {
            CrashReporter.logWarning(
                "Catalog session lookup failed sessionID=\(normalizedThreadID) error=\(error.localizedDescription)"
            )
        }

        let loadedOpenAssistSessions = await loadOpenAssistSessions(
            managedSessionIDs: Set([normalizedThreadID.lowercased()])
        )
        if let loadedSession = loadedOpenAssistSessions.first(where: {
            sessionsMatch($0.id, normalizedThreadID)
        }) {
            if !sessions.contains(where: { sessionMatchesIdentity($0, sessionID: loadedSession.id, source: loadedSession.source) }) {
                sessions.insert(loadedSession, at: 0)
            }
            ensureSessionVisible(loadedSession.id)
            await openSession(loadedSession)
            return
        }

        let loadedCopilotSessions = await loadManagedCopilotSessions(
            limit: max(80, sessions.count + 20),
            managedSessionIDs: Set([normalizedThreadID.lowercased()])
        )
        guard let loadedSession = loadedCopilotSessions.first(where: {
            sessionsMatch($0.id, normalizedThreadID)
        }) else {
            lastStatusMessage = "That thread is not available yet."
            return
        }
        if !sessions.contains(where: { sessionMatchesIdentity($0, sessionID: loadedSession.id, source: loadedSession.source) }) {
            sessions.insert(loadedSession, at: 0)
        }
        ensureSessionVisible(loadedSession.id)
        await openSession(loadedSession)
    }

    func sendPrompt(_ prompt: String) async {
        await sendPrompt(prompt, selectedPluginIDs: nil, automationJob: nil)
    }

    func sendPrompt(_ prompt: String, selectedPluginIDs: [String]? = nil) async {
        await sendPrompt(prompt, selectedPluginIDs: selectedPluginIDs, automationJob: nil)
    }

    func sendPrompt(
        _ prompt: String,
        selectedPluginIDs: [String]? = nil,
        automationJob: ScheduledJob? = nil,
        oneShotInstructions: String? = nil
    ) async {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        if let selectedSessionID,
           sessionActivitySnapshot(for: selectedSessionID).pendingPermissionRequest != nil {
            lastStatusMessage = "Answer or approve the card above to continue this turn."
            hudState = AssistantHUDState(
                phase: .waitingForPermission,
                title: "Input Needed",
                detail: "Answer or approve the card above to continue this turn."
            )
            return
        }
        guard await ensureConversationCanStart() else {
            if oneShotSessionInstructions != nil {
                oneShotSessionInstructions = nil
                syncRuntimeContext()
            }
            return
        }
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
        if let normalizedOneShotInstructions = oneShotInstructions?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty {
            oneShotSessionInstructions = [
                oneShotSessionInstructions?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
                normalizedOneShotInstructions
            ]
            .compactMap { $0 }
            .joined(separator: "\n\n")
        }
        let requestedPluginIDs = uniqueCodexPluginIDs(
            selectedPluginIDs ?? visibleSelectedComposerPlugins.map(\.pluginID)
        )
        if selectedPluginIDs == nil {
            clearComposerPlugins()
        }
        isSendingPrompt = true
        let visibleSessionID = ensureVisibleSessionForPendingPrompt()
        let visibleRuntime = ensureRuntime(for: visibleSessionID)
        let resolvedPromptState = await resolveCodexPluginPromptState(
            prompt: trimmed,
            selectedPluginIDs: requestedPluginIDs,
            backend: visibleRuntime.backend
        )
        let resolvedPrompt = resolvedPromptState.prompt
        let pendingSelectedPluginIDs = resolvedPromptState.selectedPluginIDs
        visibleRuntime.setSelectedCodexPluginIDs(pendingSelectedPluginIDs)
        let canInjectIntoActiveClaudeTurn =
            visibleRuntime.backend == .claudeCode
            && visibleRuntime.hasActiveTurn
            && visibleRuntime.hasLiveClaudeProcess
            && sessionActivitySnapshot(for: visibleSessionID).pendingPermissionRequest == nil
            && pendingAttachments.isEmpty
        let canSteerActiveCodexTurn =
            visibleRuntime.canSteerActiveTurn
            && sessionActivitySnapshot(for: visibleSessionID).pendingPermissionRequest == nil
        let shouldQueueBehindActiveTurn = assistantShouldQueuePromptBehindActiveTurn(
            sessionHasActiveTurn: sessionActivitySnapshot(for: visibleSessionID).hasActiveTurn,
            runtimeHasActiveTurn: visibleRuntime.hasActiveTurn
        ) && !canInjectIntoActiveClaudeTurn && !canSteerActiveCodexTurn
        if canInjectIntoActiveClaudeTurn {
            lastStatusMessage = "Sent your follow-up to Claude. It will continue after the current reply."
        } else if canSteerActiveCodexTurn {
            lastStatusMessage = "Steering the active turn with your follow-up."
        } else if shouldQueueBehindActiveTurn {
            lastStatusMessage = "Queued your next message. It will send after the current reply finishes."
        } else {
            stagePendingOutgoingMessage(
                prompt: resolvedPrompt,
                attachments: pendingAttachments,
                for: visibleSessionID
            )
            hudState = AssistantHUDState(
                phase: .thinking,
                title: "Thinking",
                detail: "Sending your message"
            )
        }
        defer {
            isSendingPrompt = false
            if oneShotSessionInstructions != nil {
                oneShotSessionInstructions = nil
                syncRuntimeContext()
            }
        }
        lastSubmittedPrompt = resolvedPrompt
        syncRuntimeContext()
        var executionSessionID: String?
        var executionRuntime: CodexAssistantRuntime?
        var didCommitUserMessage = false
        do {
            let sessionID = try await prepareSessionForPrompt()
            executionSessionID = sessionID
            let runtimeForSession = ensureRuntime(for: sessionID)
            executionRuntime = runtimeForSession
            let resumeContext = resumeContextIfNeeded(for: sessionID)
            let memoryContext = try memoryContextForPrompt(
                sessionID: sessionID,
                prompt: resolvedPrompt,
                automationJob: automationJob
            )
            let submittedSlashCommand = AssistantSlashCommandCatalog.detectLeadingCommand(
                in: resolvedPrompt,
                backend: runtimeForSession.backend
            )

            recordOwnedSessionID(sessionID)
            selectedSessionID = sessionID
            transcriptSessionID = sessionID
            timelineSessionID = sessionID
            ensureSessionVisible(sessionID)
            toolCalls = []
            recentToolCalls = []
            let committedMessageCreatedAt = Date()
            let committedSelectedPlugins = resolvedComposerPluginSelections(
                for: pendingSelectedPluginIDs,
                prompt: resolvedPrompt
            )
            appendTranscriptEntry(
                AssistantTranscriptEntry(
                    role: .user,
                    text: resolvedPrompt,
                    createdAt: committedMessageCreatedAt,
                    selectedPlugins: committedSelectedPlugins
                )
            )
            let imageData = pendingAttachments.filter(\.isImage).map(\.data)
            appendTimelineItem(
                .userMessage(
                    sessionID: sessionID,
                    turnID: nil,
                    text: resolvedPrompt,
                    createdAt: committedMessageCreatedAt,
                    imageAttachments: imageData.isEmpty ? nil : imageData,
                    selectedPlugins: committedSelectedPlugins,
                    source: .runtime
                )
            )
            didCommitUserMessage = true
            scheduleTrackedCodeCheckpointStartIfNeeded(for: sessionID)
            if canSteerActiveCodexTurn {
                let steeringPromptPrefix = await codexPluginContextPrefixText(
                    selectedPluginIDs: pendingSelectedPluginIDs,
                    backend: runtimeForSession.backend
                )
                try await runtimeForSession.steerActiveTurn(
                    prompt: [steeringPromptPrefix, resolvedPrompt]
                        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty }
                        .joined(separator: "\n\n"),
                    attachments: pendingAttachments
                )
                await commitPendingHistoryEditIfNeeded(for: sessionID)
                pendingResumeContextSessionIDs.remove(sessionID)
                pendingResumeContextSnapshotsBySessionID.removeValue(forKey: sessionID)
                pendingResumeContextMetadataBySessionID.removeValue(forKey: sessionID)
                ensureSessionVisible(sessionID)
                return
            }
            if shouldQueueBehindActiveTurn {
                enqueueQueuedPrompt(
                    AssistantQueuedPrompt(
                        text: resolvedPrompt,
                        attachments: pendingAttachments,
                        preferredModelID: selectedModelID,
                        modelSupportsImageInput: selectedModelSupportsImageInput,
                        selectedPluginIDs: pendingSelectedPluginIDs,
                        automationJob: automationJob,
                        createdAt: committedMessageCreatedAt,
                        submittedSlashCommand: submittedSlashCommand
                    ),
                    for: sessionID
                )
                await commitPendingHistoryEditIfNeeded(for: sessionID)
                pendingResumeContextSessionIDs.remove(sessionID)
                pendingResumeContextSnapshotsBySessionID.removeValue(forKey: sessionID)
                pendingResumeContextMetadataBySessionID.removeValue(forKey: sessionID)
                ensureSessionVisible(sessionID)
                return
            }
            let pluginInputItems = await resolvedCodexPluginPromptItems(
                selectedPluginIDs: pendingSelectedPluginIDs,
                prompt: resolvedPrompt,
                backend: runtimeForSession.backend
            )
            try await runtimeForSession.sendPrompt(
                resolvedPrompt,
                attachments: pendingAttachments,
                preferredModelID: selectedModelID,
                modelSupportsImageInput: selectedModelSupportsImageInput,
                resumeContext: resumeContext,
                memoryContext: memoryContext,
                submittedSlashCommand: submittedSlashCommand,
                structuredInputItems: pluginInputItems
            )
            await commitPendingHistoryEditIfNeeded(for: sessionID)
            pendingResumeContextSessionIDs.remove(sessionID)
            pendingResumeContextSnapshotsBySessionID.removeValue(forKey: sessionID)
            pendingResumeContextMetadataBySessionID.removeValue(forKey: sessionID)
            ensureSessionVisible(sessionID)
        } catch {
            let pendingSessionCandidates = [
                executionSessionID,
                executionRuntime.flatMap {
                    self.resolveRuntimeSessionID(
                        for: $0,
                        preferredSessionID: selectedSessionID
                    )
                },
                selectedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
                visibleSessionID
            ]
            var clearedPendingSessionIDs = Set<String>()
            for candidate in pendingSessionCandidates.compactMap({ $0 }) {
                let normalizedCandidate = candidate.lowercased()
                guard clearedPendingSessionIDs.insert(normalizedCandidate).inserted else {
                    continue
                }
                clearPendingSendState(for: candidate)
            }

            let executionBackend = executionRuntime?.backend ?? assistantBackend
            let providerRecoveryMessage: String = {
                switch executionBackend {
                case .copilot:
                    return "GitHub Copilot had an internal session problem. Open Assist repaired the Copilot session. Use Try again."
                case .claudeCode:
                    return "Claude had a saved session problem. Open Assist repaired the Claude session. Use Try again."
                case .codex:
                    return "The assistant session had an internal problem. Open Assist repaired it. Use Try again."
                case .ollamaLocal:
                    return "The local Ollama session had an internal problem. Open Assist repaired it. Use Try again."
                }
            }()

            let recoveredBrokenProviderSession = await recoverStoredProviderSessionIfNeeded(
                after: error,
                threadID: executionSessionID,
                backend: executionBackend,
                statusMessageOverride: providerRecoveryMessage
            )

            if recoveredBrokenProviderSession {
                let recoveryMessage = lastStatusMessage
                    ?? providerRecoveryMessage
                hudState = AssistantHUDState(
                    phase: .failed,
                    title: "\(executionBackend.shortDisplayName) recovered",
                    detail: recoveryMessage
                )
                if !didCommitUserMessage {
                    promptDraft = trimmed
                    attachments = pendingAttachments
                }
                if let runtimeSessionID = executionSessionID
                    ?? executionRuntime?.currentSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                    ?? selectedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
                    await discardPendingTrackedCodeCheckpoint(for: runtimeSessionID)
                }
                return
            }

            let friendlyErrorText = Self.humanizedAssistantErrorMessage(error.localizedDescription)
            hudState = AssistantHUDState(
                phase: .failed,
                title: "Send failed",
                detail: friendlyErrorText
            )
            lastStatusMessage = friendlyErrorText
            if !didCommitUserMessage {
                promptDraft = trimmed
                attachments = pendingAttachments
            }
            appendTranscriptEntry(AssistantTranscriptEntry(role: .error, text: friendlyErrorText, emphasis: true))
            appendTimelineItem(
                .system(
                    sessionID: selectedSessionID,
                    text: friendlyErrorText,
                    createdAt: Date(),
                    emphasis: true,
                    providerBackend: executionRuntime?.backend,
                    providerModelID: selectedModelID,
                    source: .runtime
                )
            )
            if let runtimeSessionID = executionSessionID
                ?? executionRuntime?.currentSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                ?? selectedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
                await discardPendingTrackedCodeCheckpoint(for: runtimeSessionID)
            }
        }
    }

    func loadSessionHistoryForAutomationSummary(sessionID: String) async -> ([AssistantTimelineItem], [AssistantTranscriptEntry]) {
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionID.isEmpty else { return ([], []) }
        let timeline = await loadPersistedTimeline(sessionID: normalizedSessionID, limit: 400)
        let transcript = await loadPersistedTranscript(sessionID: normalizedSessionID, limit: 200)
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
        if sessionActivitySnapshot(for: executionSessionID).hasActiveTurn {
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
        let cancellationSessionID = selectedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let cancellationRuntime = runtime(for: cancellationSessionID) ?? runtime
        let cancellationBackend = cancellationRuntime.backend
        let cancellationSession = cancellationSessionID.flatMap { sessionID in
            sessions.first(where: { sessionsMatch($0.id, sessionID) })
        }
        let shouldInvalidateProviderSession = Self.shouldInvalidateProviderSessionAfterUserCancellation(
            backend: cancellationBackend,
            session: cancellationSession
        )

        await cancellationRuntime.cancelActiveTurn()

        guard shouldInvalidateProviderSession,
              let cancellationSessionID else {
            return
        }

        cancellationRuntime.detachSession()
        updateProviderLink(
            forThreadID: cancellationSessionID,
            backend: cancellationBackend,
            providerSessionID: nil
        )
        markPendingResumeContext(for: cancellationSessionID)
        lastStatusMessage = "Stopped the Copilot turn. Your next message will start a fresh Copilot session inside this same chat."
    }

    func undoUserMessage(anchorID: String) async {
        guard let sessionID = selectedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            lastStatusMessage = "Open the thread first, then try again."
            return
        }
        let trackingState = effectiveCodeTrackingState(for: sessionID)
        let targetCheckpointPosition = checkpointPositionBeforeUserAnchor(anchorID, in: trackingState)
        await beginHistoryBranch(
            at: anchorID,
            kind: .undo,
            targetCheckpointPosition: targetCheckpointPosition
        )
    }

    func beginEditLastUserMessage(anchorID: String) async {
        guard let sessionID = selectedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            lastStatusMessage = "Open the thread first, then try again."
            return
        }
        let trackingState = effectiveCodeTrackingState(for: sessionID)
        let targetCheckpointPosition = checkpointPositionBeforeUserAnchor(anchorID, in: trackingState)
        await beginHistoryBranch(
            at: anchorID,
            kind: .edit,
            targetCheckpointPosition: targetCheckpointPosition
        )
    }

    func redoUndoneUserMessage() async {
        await restoreNearestHistoryBranchFutureState()
    }

    func stepHistoryBranchBackward() async {
        _ = await stepHistoryBranchBackwardOnce()
    }

    func cancelPendingHistoryEdit() async {
        await restoreNearestHistoryBranchFutureState()
    }

    func restoreHistoryRestoreItem(_ restoreID: String) async {
        await restoreHistoryBranchFutureState(id: restoreID)
    }

    private func beginHistoryBranch(
        at anchorID: String,
        kind: AssistantHistoryMutationKind,
        targetCheckpointPosition: Int
    ) async {
        let normalizedAnchorID = anchorID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedAnchorID.isEmpty else { return }
        guard let sessionID = selectedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            lastStatusMessage = "Open the thread first, then try again."
            return
        }

        if let branch = historyBranchState,
           sessionsMatch(branch.sessionID, sessionID) {
            guard kind != .edit else {
                lastStatusMessage = "Finish the current rewind before editing another message."
                return
            }
            await rewindActiveHistoryBranch(to: normalizedAnchorID)
            return
        }
        guard !isRestoringHistoryBranch else {
            return
        }
        if kind != .checkpoint {
            guard !hasPendingTrackedCodeRedo(for: sessionID) else {
                lastStatusMessage = "Finish the current code rewind or restore first."
                return
            }
        }

        isRestoringHistoryBranch = true
        defer { isRestoringHistoryBranch = false }

        await abortActiveTurnIfNeeded(for: sessionID)
        let previousDraft = promptDraft
        let previousAttachments = attachments
        let originalTrackingState = effectiveCodeTrackingState(for: sessionID)
        var restoredTrackingState = originalTrackingState
        var rewriteBackup: CodexRewriteBackup?
        var headFutureState: AssistantHistoryFutureState?

        do {
            let turns = try threadRewriteService.editableTurns(sessionID: sessionID)
            guard let targetTurn = turns.first(where: { $0.anchorID == normalizedAnchorID }) else {
                throw CodexThreadRewriteError.turnNotFound(normalizedAnchorID)
            }
            headFutureState = try await captureHistoryFutureState(
                sessionID: sessionID,
                restoreTurn: targetTurn,
                checkpointPosition: originalTrackingState.currentCheckpointPosition,
                currentAnchorIDAfterRestore: nil,
                composerPrompt: previousDraft,
                composerAttachments: previousAttachments
            )

            restoredTrackingState = try await restoreTrackedCodeFilesIfNeeded(
                sessionID: sessionID,
                state: originalTrackingState,
                targetCheckpointPosition: targetCheckpointPosition,
                publishState: false
            )

            let outcome = try threadRewriteService.truncateBeforeTurn(
                sessionID: sessionID,
                turnAnchorID: normalizedAnchorID
            )
            rewriteBackup = outcome.backup
            try await ensureRuntime(for: sessionID).resumeSessionSilently(
                runtimeResumeSessionID(forThreadID: sessionID),
                cwd: resolvedSessionCWD(for: sessionID),
                preferredModelID: selectedModelID
            )

            _ = try await applyHistoryRewriteRollback(
                for: sessionID,
                retainedAnchorIDs: outcome.retainedTurns.map(\.anchorID),
                removedAnchorIDs: outcome.removedTurns.map(\.anchorID),
                captureSnapshot: false,
                keepRemovedCheckpoints: true
            )

            let restoredTurn = outcome.removedTurns.first
            let restoredPrompt = restoredTurn?.text ?? ""
            let restoredAttachments = (restoredTurn?.imageAttachments ?? []).map(assistantAttachment(from:))
            promptDraft = restoredPrompt
            attachments = restoredAttachments

            let branchState = AssistantHistoryBranchState(
                kind: kind,
                sessionID: sessionID,
                currentAnchorID: normalizedAnchorID,
                currentCheckpointPosition: restoredTrackingState.currentCheckpointPosition,
                currentPrompt: restoredPrompt,
                currentAttachments: restoredAttachments,
                futureStates: headFutureState.map { [$0] } ?? []
            )

            historyBranchState = branchState
            persistHistoryBranchState(
                branchState,
                currentTrackingState: restoredTrackingState
            )

            await reloadAfterHistoryRewrite(for: sessionID)
            await reconcileProjectDigest(for: sessionID)
            refreshEditableTurns(for: sessionID)
            if let rewriteBackup {
                threadRewriteService.deleteBackup(rewriteBackup)
            }
            switch kind {
            case .checkpoint:
                lastStatusMessage = "Code undone. The old request is back in the text box so you can edit it."
            case .edit:
                lastStatusMessage = "Editing that message. Update it in the text box, then press Send."
            case .undo:
                lastStatusMessage = "Undid that message. It is back in the text box so you can edit it."
            }
        } catch {
            if let rewriteBackup {
                try? threadRewriteService.restoreBackup(rewriteBackup)
                threadRewriteService.deleteBackup(rewriteBackup)
            }
            if let headFutureState {
                try? await restoreHistorySnapshot(sessionID: sessionID, snapshotID: headFutureState.snapshotID)
                deleteHistorySnapshots(sessionID: sessionID, snapshotIDs: [headFutureState.snapshotID])
            }
            _ = try? await restoreTrackedCodeFilesIfNeeded(
                sessionID: sessionID,
                state: restoredTrackingState,
                targetCheckpointPosition: originalTrackingState.currentCheckpointPosition,
                publishState: false
            )
            promptDraft = previousDraft
            attachments = previousAttachments
            historyBranchState = nil
            clearPersistedHistoryBranchState(for: sessionID, currentTrackingState: originalTrackingState)
            refreshEditableTurns(for: sessionID)
            await reloadAfterHistoryRewrite(for: sessionID)
            await reconcileProjectDigest(for: sessionID)
            lastStatusMessage = error.localizedDescription
        }
    }

    private func rewindActiveHistoryBranch(to anchorID: String) async {
        while let branch = historyBranchState,
              sessionsMatch(branch.sessionID, selectedSessionID),
              branch.currentAnchorID != anchorID {
            let stepped = await stepHistoryBranchBackwardOnce()
            guard stepped else { return }
        }
    }

    @discardableResult
    private func stepHistoryBranchBackwardOnce() async -> Bool {
        guard let branch = historyBranchState else {
            return false
        }
        guard !isRestoringHistoryBranch else {
            return false
        }

        let sessionID = branch.sessionID
        let previousDraft = promptDraft
        let previousAttachments = attachments
        let currentTrackingState = effectiveCodeTrackingState(for: sessionID)
        let currentCheckpointPosition = currentTrackingState.currentCheckpointPosition

        let previousTurn: CodexEditableTurn
        do {
            let turns = try threadRewriteService.editableTurns(sessionID: sessionID)
            guard let lastTurn = turns.last else {
                lastStatusMessage = "There is no earlier message to go back to."
                return false
            }
            previousTurn = lastTurn
        } catch {
            lastStatusMessage = error.localizedDescription
            return false
        }

        isRestoringHistoryBranch = true
        defer { isRestoringHistoryBranch = false }

        await abortActiveTurnIfNeeded(for: sessionID)
        var restoredTrackingState = currentTrackingState
        var stepBackup: CodexRewriteBackup?
        var currentFutureState: AssistantHistoryFutureState?

        do {
            currentFutureState = try await captureCurrentHistoryFutureState(
                sessionID: sessionID,
                branch: branch,
                checkpointPosition: currentTrackingState.currentCheckpointPosition
            )

            let targetCheckpointPosition = checkpointPositionBeforeUserAnchor(
                previousTurn.anchorID,
                in: currentTrackingState
            )
            restoredTrackingState = try await restoreTrackedCodeFilesIfNeeded(
                sessionID: sessionID,
                state: currentTrackingState,
                targetCheckpointPosition: targetCheckpointPosition,
                publishState: false
            )

            let outcome = try threadRewriteService.truncateBeforeTurn(
                sessionID: sessionID,
                turnAnchorID: previousTurn.anchorID
            )
            stepBackup = outcome.backup
            try await ensureRuntime(for: sessionID).resumeSessionSilently(
                runtimeResumeSessionID(forThreadID: sessionID),
                cwd: resolvedSessionCWD(for: sessionID),
                preferredModelID: selectedModelID
            )

            _ = try await applyHistoryRewriteRollback(
                for: sessionID,
                retainedAnchorIDs: outcome.retainedTurns.map(\.anchorID),
                removedAnchorIDs: outcome.removedTurns.map(\.anchorID),
                captureSnapshot: false,
                keepRemovedCheckpoints: true
            )

            let restoredPrompt = outcome.removedTurns.first?.text ?? previousTurn.text
            let restoredAttachments = (outcome.removedTurns.first?.imageAttachments ?? previousTurn.imageAttachments)
                .map(assistantAttachment(from:))

            promptDraft = restoredPrompt
            attachments = restoredAttachments

            let updatedBranch = AssistantHistoryBranchState(
                kind: branch.kind,
                sessionID: sessionID,
                currentAnchorID: previousTurn.anchorID,
                currentCheckpointPosition: restoredTrackingState.currentCheckpointPosition,
                currentPrompt: restoredPrompt,
                currentAttachments: restoredAttachments,
                futureStates: ([currentFutureState].compactMap { $0 }) + branch.futureStates
            )

            historyBranchState = updatedBranch
            persistHistoryBranchState(
                updatedBranch,
                currentTrackingState: restoredTrackingState
            )

            await reloadAfterHistoryRewrite(for: sessionID)
            await reconcileProjectDigest(for: sessionID)
            refreshEditableTurns(for: sessionID)
            if let stepBackup {
                threadRewriteService.deleteBackup(stepBackup)
            }
            lastStatusMessage = "Moved back one more message. The older request is now in the text box."
            return true
        } catch {
            if let stepBackup {
                try? threadRewriteService.restoreBackup(stepBackup)
                threadRewriteService.deleteBackup(stepBackup)
            }
            if let currentFutureState {
                try? await restoreHistorySnapshot(sessionID: sessionID, snapshotID: currentFutureState.snapshotID)
                deleteHistorySnapshots(sessionID: sessionID, snapshotIDs: [currentFutureState.snapshotID])
            }
            _ = try? await restoreTrackedCodeFilesIfNeeded(
                sessionID: sessionID,
                state: restoredTrackingState,
                targetCheckpointPosition: currentCheckpointPosition,
                publishState: false
            )
            promptDraft = previousDraft
            attachments = previousAttachments
            historyBranchState = branch
            persistHistoryBranchState(branch, currentTrackingState: currentTrackingState)
            await reloadAfterHistoryRewrite(for: sessionID)
            await reconcileProjectDigest(for: sessionID)
            refreshEditableTurns(for: sessionID)
            lastStatusMessage = error.localizedDescription
            return false
        }
    }

    private func restoreNearestHistoryBranchFutureState() async {
        guard let futureID = historyBranchState?.futureStates.first?.id else {
            return
        }
        await restoreHistoryBranchFutureState(id: futureID)
    }

    private func restoreHistoryBranchFutureState(id futureID: String) async {
        guard let branch = historyBranchState,
              let restoreIndex = branch.futureStates.firstIndex(where: { $0.id == futureID }) else {
            return
        }
        guard !isRestoringHistoryBranch else {
            return
        }

        let sessionID = branch.sessionID
        let futureState = branch.futureStates[restoreIndex]
        let remainingFutureStates = Array(branch.futureStates.dropFirst(restoreIndex + 1))
        let previousDraft = promptDraft
        let previousAttachments = attachments
        let startingTrackingState = effectiveCodeTrackingState(for: sessionID)
        var restoredTrackingState = startingTrackingState
        var rollbackSnapshotID: String?

        isRestoringHistoryBranch = true
        defer { isRestoringHistoryBranch = false }

        await abortActiveTurnIfNeeded(for: sessionID)

        do {
            rollbackSnapshotID = try await captureHistorySnapshot(sessionID: sessionID)
            restoredTrackingState = try await restoreTrackedCodeFilesIfNeeded(
                sessionID: sessionID,
                state: startingTrackingState,
                targetCheckpointPosition: futureState.checkpointPosition,
                publishState: false
            )
            try await restoreHistorySnapshot(sessionID: sessionID, snapshotID: futureState.snapshotID)
            try await ensureRuntime(for: sessionID).resumeSessionSilently(
                runtimeResumeSessionID(forThreadID: sessionID),
                cwd: resolvedSessionCWD(for: sessionID),
                preferredModelID: selectedModelID
            )

            promptDraft = futureState.composerPrompt
            attachments = futureState.composerAttachments

            let consumedSnapshotIDs = Array(branch.futureStates.prefix(restoreIndex + 1).map(\.snapshotID))
            if let nextCurrentAnchorID = futureState.currentAnchorIDAfterRestore {
                let updatedBranch = AssistantHistoryBranchState(
                    kind: branch.kind,
                    sessionID: sessionID,
                    currentAnchorID: nextCurrentAnchorID,
                    currentCheckpointPosition: futureState.checkpointPosition,
                    currentPrompt: futureState.composerPrompt,
                    currentAttachments: futureState.composerAttachments,
                    futureStates: remainingFutureStates
                )
                historyBranchState = updatedBranch
                persistHistoryBranchState(updatedBranch, currentTrackingState: restoredTrackingState)
                lastStatusMessage = "Restored that hidden message."
            } else {
                historyBranchState = nil
                clearPersistedHistoryBranchState(for: sessionID, currentTrackingState: restoredTrackingState)
                lastStatusMessage = "Restored the original branch."
            }

            deleteHistorySnapshots(sessionID: sessionID, snapshotIDs: consumedSnapshotIDs)
            if let rollbackSnapshotID {
                deleteHistorySnapshots(sessionID: sessionID, snapshotIDs: [rollbackSnapshotID])
            }
            await reloadAfterHistoryRewrite(for: sessionID)
            await reconcileProjectDigest(for: sessionID)
            refreshEditableTurns(for: sessionID)
        } catch {
            if let rollbackSnapshotID {
                try? await restoreHistorySnapshot(sessionID: sessionID, snapshotID: rollbackSnapshotID)
                deleteHistorySnapshots(sessionID: sessionID, snapshotIDs: [rollbackSnapshotID])
            }
            _ = try? await restoreTrackedCodeFilesIfNeeded(
                sessionID: sessionID,
                state: restoredTrackingState,
                targetCheckpointPosition: startingTrackingState.currentCheckpointPosition,
                publishState: false
            )
            promptDraft = previousDraft
            attachments = previousAttachments
            historyBranchState = branch
            persistHistoryBranchState(branch, currentTrackingState: startingTrackingState)
            lastStatusMessage = error.localizedDescription
        }
    }

    private func createHistorySnapshotID() -> String {
        "history-\(UUID().uuidString.lowercased())"
    }

    private func captureHistorySnapshot(sessionID: String) async throws -> String {
        let snapshotID = createHistorySnapshotID()
        try await conversationCheckpointStore.captureSnapshot(
            sessionID: sessionID,
            checkpointID: snapshotID,
            phase: .after
        )
        return snapshotID
    }

    private func restoreHistorySnapshot(sessionID: String, snapshotID: String) async throws {
        try await conversationCheckpointStore.restoreSnapshot(
            sessionID: sessionID,
            checkpointID: snapshotID,
            phase: .after
        )
    }

    private func deleteHistorySnapshots(sessionID: String, snapshotIDs: [String]) {
        guard !snapshotIDs.isEmpty else { return }
        conversationCheckpointStore.deleteCheckpoints(
            sessionID: sessionID,
            checkpointIDs: snapshotIDs
        )
    }

    private func historyFutureStateTitle(for turn: CodexEditableTurn) -> String {
        let trimmed = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Earlier message" : trimmed
    }

    private func captureHistoryFutureState(
        sessionID: String,
        restoreTurn: CodexEditableTurn,
        checkpointPosition: Int,
        currentAnchorIDAfterRestore: String?,
        composerPrompt: String,
        composerAttachments: [AssistantAttachment]
    ) async throws -> AssistantHistoryFutureState {
        let snapshotID = try await captureHistorySnapshot(sessionID: sessionID)
        return AssistantHistoryFutureState(
            restoreAnchorID: restoreTurn.anchorID,
            title: historyFutureStateTitle(for: restoreTurn),
            snapshotID: snapshotID,
            checkpointPosition: checkpointPosition,
            currentAnchorIDAfterRestore: currentAnchorIDAfterRestore,
            composerPrompt: composerPrompt,
            composerAttachments: composerAttachments
        )
    }

    private func captureCurrentHistoryFutureState(
        sessionID: String,
        branch: AssistantHistoryBranchState,
        checkpointPosition: Int
    ) async throws -> AssistantHistoryFutureState {
        let turns = try threadRewriteService.editableTurns(sessionID: sessionID)
        guard let restoreTurn = turns.last else {
            throw CodexThreadRewriteError.turnNotFound(branch.currentAnchorID)
        }
        return try await captureHistoryFutureState(
            sessionID: sessionID,
            restoreTurn: restoreTurn,
            checkpointPosition: checkpointPosition,
            currentAnchorIDAfterRestore: branch.currentAnchorID,
            composerPrompt: branch.currentPrompt,
            composerAttachments: branch.currentAttachments
        )
    }

    private func abortActiveTurnIfNeeded(for sessionID: String) async {
        let sessionRuntime = ensureRuntime(for: sessionID)
        guard sessionActivitySnapshot(for: sessionID).hasActiveTurn || sessionRuntime.hasActiveTurn else {
            return
        }
        await sessionRuntime.cancelActiveTurn()
        for _ in 0..<20 {
            if !sessionActivitySnapshot(for: sessionID).hasActiveTurn && !sessionRuntime.hasActiveTurn {
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func resolveHistoryRewindAnchorID(
        for checkpoint: AssistantCodeCheckpointSummary,
        sessionID: String
    ) throws -> String {
        if let anchorID = checkpoint.associatedUserAnchorID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty {
            return anchorID
        }

        let turns = try threadRewriteService.editableTurns(sessionID: sessionID)
        if let datedMatch = turns.last(where: { $0.createdAt <= checkpoint.createdAt }) {
            return datedMatch.anchorID
        }
        if let lastTurn = turns.last {
            return lastTurn.anchorID
        }

        throw AssistantHistoryMutationError.missingCheckpointAnchor
    }

    private func restoreTrackedCodeFilesIfNeeded(
        sessionID: String,
        state: AssistantCodeTrackingState,
        targetCheckpointPosition: Int,
        publishState: Bool
    ) async throws -> AssistantCodeTrackingState {
        guard state.currentCheckpointPosition != targetCheckpointPosition else {
            if publishState {
                publishCodeTrackingState(state)
            }
            return state
        }

        guard let repoRootPath = state.repoRootPath,
              let repoLabel = state.repoLabel else {
            throw AssistantHistoryMutationError.missingRepository
        }

        guard targetCheckpointPosition >= -1,
              targetCheckpointPosition < state.checkpoints.count else {
            throw AssistantHistoryMutationError.invalidCheckpointTarget
        }

        guard !state.checkpoints.isEmpty else {
            if targetCheckpointPosition == -1 {
                if publishState {
                    publishCodeTrackingState(state)
                }
                return state
            }
            throw AssistantHistoryMutationError.invalidCheckpointTarget
        }

        let repository = GitCheckpointRepositoryContext(
            rootPath: repoRootPath,
            label: repoLabel
        )

        let sourceCheckpoint: AssistantCodeCheckpointSummary
        let sourcePhase: AssistantCodeCheckpointPhase
        let sourceSnapshot: GitCheckpointSnapshot

        if state.currentCheckpointPosition >= 0,
           state.checkpoints.indices.contains(state.currentCheckpointPosition) {
            let checkpoint = state.checkpoints[state.currentCheckpointPosition]
            sourceCheckpoint = checkpoint
            sourcePhase = .after
            sourceSnapshot = checkpoint.afterSnapshot
        } else {
            let checkpoint = state.checkpoints[0]
            sourceCheckpoint = checkpoint
            sourcePhase = .before
            sourceSnapshot = checkpoint.beforeSnapshot
        }

        let restoreCheckpoint: AssistantCodeCheckpointSummary
        let targetPhase: AssistantCodeCheckpointPhase
        if targetCheckpointPosition >= 0 {
            let checkpoint = state.checkpoints[targetCheckpointPosition]
            restoreCheckpoint = checkpoint
            targetPhase = .after
        } else {
            let checkpoint = state.checkpoints[0]
            restoreCheckpoint = checkpoint
            targetPhase = .before
        }

        let guardResult = try await gitCheckpointService.restoreGuard(
            repository: repository,
            expectedWorktreeTree: sourceSnapshot.worktreeTree,
            expectedIndexTree: sourceSnapshot.indexTree
        )
        guard guardResult.isAllowed else {
            throw GitCheckpointServiceError.gitCommandFailed(
                guardResult.message
                    ?? "Open Assist can’t undo right now because the repository changed after the last saved checkpoint."
            )
        }

        do {
            try await gitCheckpointService.restore(
                repository: repository,
                files: restoreCheckpoint.changedFiles,
                target: targetPhase
            )
        } catch {
            try? await gitCheckpointService.restore(
                repository: repository,
                files: sourceCheckpoint.changedFiles,
                target: sourcePhase
            )
            throw error
        }

        var updatedState = state
        updatedState.currentCheckpointPosition = targetCheckpointPosition
        if publishState {
            publishCodeTrackingState(updatedState)
        }
        return updatedState
    }

    func deleteSession(_ sessionID: String) async {
        await deleteSession(sessionID, showStatusMessage: true)
    }

    func archiveSession(
        _ sessionID: String,
        retentionHours: Int,
        updateDefaultRetention: Bool
    ) async {
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? ""
        guard !normalizedSessionID.isEmpty else { return }

        if let sessionRuntime = runtime(for: normalizedSessionID),
           sessionRuntime.hasActiveTurn {
            lastStatusMessage = "Wait for the current reply to finish before archiving this chat."
            return
        }
        if sessionsMatch(rootRuntime.currentSessionID, normalizedSessionID),
           rootRuntime.hasActiveTurn {
            lastStatusMessage = "Wait for the current reply to finish before archiving this chat."
            return
        }

        let normalizedRetentionHours = normalizedArchiveRetentionHours(retentionHours)
        if updateDefaultRetention {
            settings.assistantArchiveDefaultRetentionHours = normalizedRetentionHours
        }

        do {
            let knownSessions = await knownSessionsForCleanup(anchoredTo: normalizedSessionID)
            let descendantSessionIDs = assistantChildSessionIDs(
                parentSessionID: normalizedSessionID,
                sessions: knownSessions
            )
            let targetSessionIDs = Array(Set([normalizedSessionID] + descendantSessionIDs))
            let archivedAt = Date()
            let expiresAt = archivedAt.addingTimeInterval(TimeInterval(normalizedRetentionHours * 60 * 60))
            let usesDefaultRetention = normalizedRetentionHours == normalizedArchiveRetentionHours(
                settings.assistantArchiveDefaultRetentionHours
            )

            for candidateSessionID in targetSessionIDs {
                setTemporaryFlag(false, for: candidateSessionID, reportErrors: false)
                try sessionCatalog.archiveSession(
                    sessionID: candidateSessionID,
                    archivedAt: archivedAt,
                    expiresAt: expiresAt,
                    usesDefaultRetention: usesDefaultRetention
                )
            }
            try sessionRegistry.setArchiveState(
                sessionIDs: targetSessionIDs,
                sources: Set([.openAssist, .cli]),
                isArchived: true,
                archivedAt: archivedAt,
                expiresAt: expiresAt,
                usesDefaultRetention: usesDefaultRetention
            )

            if let currentSelectedSessionID = selectedSessionID,
               targetSessionIDs.contains(where: { sessionsMatch($0, currentSelectedSessionID) }) {
                selectedSessionID = nil
                transcriptSessionID = nil
                timelineSessionID = nil
                timelineItems = []
                clearActiveProposedPlanIfNeeded(for: nil)
            }

            await refreshSessions()
            lastStatusMessage = "Archived the chat. It will be deleted after \(archiveRetentionDescription(hours: normalizedRetentionHours))."
        } catch {
            lastStatusMessage = error.localizedDescription
        }
    }

    func unarchiveSession(_ sessionID: String) async {
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? ""
        guard !normalizedSessionID.isEmpty else { return }

        do {
            let knownSessions = await knownSessionsForCleanup(anchoredTo: normalizedSessionID)
            let descendantSessionIDs = assistantChildSessionIDs(
                parentSessionID: normalizedSessionID,
                sessions: knownSessions
            )
            let targetSessionIDs = Array(Set([normalizedSessionID] + descendantSessionIDs))

            for candidateSessionID in targetSessionIDs {
                try sessionCatalog.unarchiveSession(sessionID: candidateSessionID)
            }
            try sessionRegistry.setArchiveState(
                sessionIDs: targetSessionIDs,
                sources: Set([.openAssist, .cli]),
                isArchived: false,
                archivedAt: nil,
                expiresAt: nil,
                usesDefaultRetention: nil
            )

            await refreshSessions()
            lastStatusMessage = "Moved the chat back to active threads."
        } catch {
            lastStatusMessage = error.localizedDescription
        }
    }

    func loadThreadNote(threadID: String?) -> String {
        guard let normalizedThreadID = normalizedSessionID(threadID) else { return "" }
        return conversationStore.loadThreadNote(threadID: normalizedThreadID)
    }

    func loadThreadNotesWorkspace(threadID: String?) -> AssistantThreadNotesWorkspace? {
        guard let normalizedThreadID = normalizedSessionID(threadID) else { return nil }
        return conversationStore.loadThreadNotesWorkspace(threadID: normalizedThreadID)
    }

    func loadThreadStoredNotes(threadID: String?) -> [AssistantStoredNote] {
        guard let normalizedThreadID = normalizedSessionID(threadID) else { return [] }
        return conversationStore.loadThreadStoredNotes(threadID: normalizedThreadID)
    }

    /// On-disk URL for the given note's markdown file, or nil if the owner /
    /// note cannot be resolved or the file isn't written yet.
    func noteMarkdownFileURL(
        ownerKind: AssistantNoteOwnerKind,
        ownerID: String,
        noteID: String
    ) -> URL? {
        let trimmedOwner = ownerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNoteID = noteID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOwner.isEmpty, !trimmedNoteID.isEmpty else { return nil }
        switch ownerKind {
        case .thread:
            guard let normalizedThreadID = normalizedSessionID(trimmedOwner) else { return nil }
            return conversationStore.threadNoteOnDiskURL(
                threadID: normalizedThreadID,
                noteID: trimmedNoteID
            )
        case .project:
            return projectStore.projectNoteOnDiskURL(
                projectID: trimmedOwner,
                noteID: trimmedNoteID
            )
        }
    }

    func threadNoteLastSavedAt(threadID: String?) -> Date? {
        guard let normalizedThreadID = normalizedSessionID(threadID) else { return nil }
        return conversationStore.threadNoteModificationDate(threadID: normalizedThreadID)
    }

    func saveThreadNote(threadID: String?, text: String) -> Bool {
        guard let normalizedThreadID = normalizedSessionID(threadID) else { return false }
        do {
            try conversationStore.saveThreadNote(threadID: normalizedThreadID, text: text)
            _ = try? AssistantNotesBackupController.shared.maybeRunAutomaticBackupIfNeeded()
            return true
        } catch {
            lastStatusMessage = "Could not save the thread note."
            CrashReporter.logError("Thread note save failed: \(error.localizedDescription)")
            return false
        }
    }

    func createThreadNote(
        threadID: String?,
        title: String? = nil,
        noteType: AssistantNoteType = .note,
        selectNewNote: Bool = true
    ) -> AssistantThreadNotesWorkspace? {
        guard let normalizedThreadID = normalizedSessionID(threadID) else { return nil }
        do {
            return try conversationStore.createThreadNote(
                threadID: normalizedThreadID,
                title: title,
                noteType: noteType,
                selectNewNote: selectNewNote
            )
        } catch {
            lastStatusMessage = "Could not create the thread note."
            CrashReporter.logError("Thread note create failed: \(error.localizedDescription)")
            return nil
        }
    }

    func renameThreadNote(
        threadID: String?,
        noteID: String?,
        title: String
    ) -> AssistantThreadNotesWorkspace? {
        guard let normalizedThreadID = normalizedSessionID(threadID),
              let noteID = noteID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return nil
        }
        do {
            return try conversationStore.renameThreadNote(
                threadID: normalizedThreadID,
                noteID: noteID,
                title: title
            )
        } catch {
            lastStatusMessage = "Could not rename the thread note."
            CrashReporter.logError("Thread note rename failed: \(error.localizedDescription)")
            return nil
        }
    }

    func selectThreadNote(
        threadID: String?,
        noteID: String?
    ) -> AssistantThreadNotesWorkspace? {
        guard let normalizedThreadID = normalizedSessionID(threadID),
              let noteID = noteID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return nil
        }
        do {
            return try conversationStore.selectThreadNote(
                threadID: normalizedThreadID,
                noteID: noteID
            )
        } catch {
            lastStatusMessage = "Could not switch thread notes."
            CrashReporter.logError("Thread note select failed: \(error.localizedDescription)")
            return nil
        }
    }

    func saveThreadNote(
        threadID: String?,
        noteID: String?,
        text: String,
        forceHistorySnapshot: Bool = false
    ) -> AssistantThreadNotesWorkspace? {
        guard let normalizedThreadID = normalizedSessionID(threadID) else { return nil }
        let normalizedNoteID = noteID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        do {
            let workspace = try conversationStore.saveThreadNote(
                threadID: normalizedThreadID,
                noteID: normalizedNoteID,
                text: text,
                forceHistorySnapshot: forceHistorySnapshot
            )
            _ = try? AssistantNotesBackupController.shared.maybeRunAutomaticBackupIfNeeded()
            return workspace
        } catch {
            lastStatusMessage = "Could not save the thread note."
            CrashReporter.logError("Thread note save failed: \(error.localizedDescription)")
            return nil
        }
    }

    func saveThreadNoteImageAsset(
        threadID: String?,
        noteID: String?,
        attachment: AssistantAttachment
    ) -> AssistantSavedNoteAsset? {
        guard let normalizedThreadID = normalizedSessionID(threadID),
              let noteID = noteID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return nil
        }

        do {
            let asset = try conversationStore.saveThreadNoteImageAsset(
                threadID: normalizedThreadID,
                noteID: noteID,
                attachment: attachment
            )
            _ = try? AssistantNotesBackupController.shared.maybeRunAutomaticBackupIfNeeded()
            return asset
        } catch {
            lastStatusMessage = "Could not save that image in the thread note."
            CrashReporter.logError("Thread note image save failed: \(error.localizedDescription)")
            return nil
        }
    }

    func resolveThreadNoteImageAssetURL(
        threadID: String?,
        noteID: String?,
        relativePath: String
    ) -> URL? {
        guard let normalizedThreadID = normalizedSessionID(threadID),
              let noteID = noteID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return nil
        }

        return conversationStore.resolveThreadNoteImageAssetURL(
            threadID: normalizedThreadID,
            noteID: noteID,
            relativePath: relativePath
        )
    }

    func deleteThreadNote(
        threadID: String?,
        noteID: String?
    ) -> AssistantThreadNotesWorkspace? {
        guard let normalizedThreadID = normalizedSessionID(threadID),
              let noteID = noteID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return nil
        }
        do {
            let workspace = try conversationStore.deleteThreadNote(
                threadID: normalizedThreadID,
                noteID: noteID
            )
            _ = try? AssistantNotesBackupController.shared.maybeRunAutomaticBackupIfNeeded()
            return workspace
        } catch {
            lastStatusMessage = "Could not delete the thread note."
            CrashReporter.logError("Thread note delete failed: \(error.localizedDescription)")
            return nil
        }
    }

    func threadNoteHistoryVersions(
        threadID: String?,
        noteID: String?
    ) -> [AssistantNoteHistoryVersion] {
        guard let normalizedThreadID = normalizedSessionID(threadID),
              let noteID = noteID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return []
        }
        return conversationStore.threadNoteHistoryVersions(
            threadID: normalizedThreadID,
            noteID: noteID
        )
    }

    func restoreThreadNoteHistoryVersion(
        threadID: String?,
        noteID: String?,
        versionID: String?
    ) -> AssistantThreadNotesWorkspace? {
        guard let normalizedThreadID = normalizedSessionID(threadID),
              let noteID = noteID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
              let versionID = versionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return nil
        }
        do {
            let workspace = try conversationStore.restoreThreadNoteHistoryVersion(
                threadID: normalizedThreadID,
                noteID: noteID,
                versionID: versionID
            )
            _ = try? AssistantNotesBackupController.shared.maybeRunAutomaticBackupIfNeeded()
            return workspace
        } catch {
            lastStatusMessage = "Could not restore that note version."
            CrashReporter.logError("Thread note history restore failed: \(error.localizedDescription)")
            return nil
        }
    }

    func deleteThreadNoteHistoryVersion(
        threadID: String?,
        noteID: String?,
        versionID: String?
    ) -> AssistantThreadNotesWorkspace? {
        guard let normalizedThreadID = normalizedSessionID(threadID),
              let noteID = noteID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
              let versionID = versionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return nil
        }
        return conversationStore.deleteThreadNoteHistoryVersion(
            threadID: normalizedThreadID,
            noteID: noteID,
            versionID: versionID
        )
    }

    func recentlyDeletedThreadNotes(threadID: String?) -> [AssistantDeletedNoteSnapshot] {
        guard let normalizedThreadID = normalizedSessionID(threadID) else { return [] }
        return conversationStore.recentlyDeletedThreadNotes(threadID: normalizedThreadID)
    }

    func restoreDeletedThreadNote(
        threadID: String?,
        deletedNoteID: String?
    ) -> AssistantThreadNotesWorkspace? {
        guard let normalizedThreadID = normalizedSessionID(threadID),
              let deletedNoteID = deletedNoteID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return nil
        }
        do {
            let workspace = try conversationStore.restoreDeletedThreadNote(
                threadID: normalizedThreadID,
                deletedNoteID: deletedNoteID
            )
            _ = try? AssistantNotesBackupController.shared.maybeRunAutomaticBackupIfNeeded()
            return workspace
        } catch {
            lastStatusMessage = "Could not restore that deleted note."
            CrashReporter.logError("Thread note deleted restore failed: \(error.localizedDescription)")
            return nil
        }
    }

    func permanentlyDeleteDeletedThreadNote(
        threadID: String?,
        deletedNoteID: String?
    ) {
        guard let normalizedThreadID = normalizedSessionID(threadID),
              let deletedNoteID = deletedNoteID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return
        }
        conversationStore.permanentlyDeleteDeletedThreadNote(
            threadID: normalizedThreadID,
            deletedNoteID: deletedNoteID
        )
    }

    func appendToSelectedThreadNote(
        threadID: String?,
        text: String
    ) -> AssistantThreadNotesWorkspace? {
        guard let normalizedThreadID = normalizedSessionID(threadID) else { return nil }
        do {
            return try conversationStore.appendToSelectedThreadNote(
                threadID: normalizedThreadID,
                text: text
            )
        } catch {
            lastStatusMessage = "Could not add that text to the current note."
            CrashReporter.logError("Thread note append failed: \(error.localizedDescription)")
            return nil
        }
    }

    func loadProjectNotesWorkspace(projectID: String?) -> AssistantNotesWorkspace? {
        guard let normalizedProjectID = projectID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return nil
        }
        do {
            return try projectStore.loadProjectNotesWorkspace(projectID: normalizedProjectID)
        } catch {
            lastStatusMessage = "Could not load the project notes."
            CrashReporter.logError("Project note load failed: \(error.localizedDescription)")
            return nil
        }
    }

    func loadProjectStoredNotes(projectID: String?) -> [AssistantStoredNote] {
        guard let normalizedProjectID = projectID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return []
        }
        do {
            return try projectStore.loadProjectStoredNotes(projectID: normalizedProjectID)
        } catch {
            lastStatusMessage = "Could not load the project notes."
            CrashReporter.logError("Project note list failed: \(error.localizedDescription)")
            return []
        }
    }

    func projectNoteFolders(projectID: String?) -> [AssistantNoteFolderSummary] {
        guard let normalizedProjectID = projectID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return []
        }
        do {
            return try projectStore.projectNoteFolders(projectID: normalizedProjectID)
        } catch {
            lastStatusMessage = "Could not load the project note folders."
            CrashReporter.logError("Project note folders failed: \(error.localizedDescription)")
            return []
        }
    }

    func projectNoteFolderPathMap(projectID: String?) -> [String: [String]] {
        guard let normalizedProjectID = projectID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return [:]
        }
        do {
            return try projectStore.projectNoteFolderPathMap(projectID: normalizedProjectID)
        } catch {
            lastStatusMessage = "Could not load the project note folders."
            CrashReporter.logError("Project note folder paths failed: \(error.localizedDescription)")
            return [:]
        }
    }

    func projectNoteLastSavedAt(projectID: String?) -> Date? {
        guard let normalizedProjectID = projectID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return nil
        }
        return try? projectStore.projectNoteModificationDate(projectID: normalizedProjectID)
    }

    func createProjectNote(
        projectID: String?,
        title: String? = nil,
        noteType: AssistantNoteType = .note,
        selectNewNote: Bool = true,
        folderID: String? = nil
    ) -> AssistantNotesWorkspace? {
        guard let normalizedProjectID = projectID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return nil
        }
        do {
            return try projectStore.createProjectNote(
                projectID: normalizedProjectID,
                title: title,
                noteType: noteType,
                selectNewNote: selectNewNote,
                folderID: folderID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            )
        } catch {
            lastStatusMessage = "Could not create the project note."
            CrashReporter.logError("Project note create failed: \(error.localizedDescription)")
            return nil
        }
    }

    func createProjectNoteFolder(
        projectID: String?,
        parentFolderID: String? = nil,
        name: String
    ) -> AssistantNotesWorkspace? {
        guard let normalizedProjectID = projectID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return nil
        }
        do {
            return try projectStore.createProjectNoteFolder(
                projectID: normalizedProjectID,
                parentFolderID: parentFolderID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
                name: name
            )
        } catch {
            lastStatusMessage = "Could not create the note folder."
            CrashReporter.logError("Project note folder create failed: \(error.localizedDescription)")
            return nil
        }
    }

    func renameProjectNoteFolder(
        projectID: String?,
        folderID: String?,
        name: String
    ) -> AssistantNotesWorkspace? {
        guard let normalizedProjectID = projectID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
              let normalizedFolderID = folderID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return nil
        }
        do {
            return try projectStore.renameProjectNoteFolder(
                projectID: normalizedProjectID,
                folderID: normalizedFolderID,
                name: name
            )
        } catch {
            lastStatusMessage = "Could not rename the note folder."
            CrashReporter.logError("Project note folder rename failed: \(error.localizedDescription)")
            return nil
        }
    }

    func moveProjectNoteFolder(
        projectID: String?,
        folderID: String?,
        parentFolderID: String?
    ) -> AssistantNotesWorkspace? {
        guard let normalizedProjectID = projectID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
              let normalizedFolderID = folderID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return nil
        }
        do {
            return try projectStore.moveProjectNoteFolder(
                projectID: normalizedProjectID,
                folderID: normalizedFolderID,
                parentFolderID: parentFolderID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            )
        } catch {
            lastStatusMessage = "Could not move the note folder."
            CrashReporter.logError("Project note folder move failed: \(error.localizedDescription)")
            return nil
        }
    }

    func deleteProjectNoteFolder(
        projectID: String?,
        folderID: String?
    ) -> AssistantNotesWorkspace? {
        guard let normalizedProjectID = projectID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
              let normalizedFolderID = folderID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return nil
        }
        do {
            return try projectStore.deleteProjectNoteFolder(
                projectID: normalizedProjectID,
                folderID: normalizedFolderID
            )
        } catch {
            lastStatusMessage = "Could not delete the note folder."
            CrashReporter.logError("Project note folder delete failed: \(error.localizedDescription)")
            return nil
        }
    }

    func moveProjectNote(
        projectID: String?,
        noteID: String?,
        folderID: String?
    ) -> AssistantNotesWorkspace? {
        guard let normalizedProjectID = projectID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
              let normalizedNoteID = noteID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return nil
        }
        do {
            return try projectStore.moveProjectNote(
                projectID: normalizedProjectID,
                noteID: normalizedNoteID,
                folderID: folderID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            )
        } catch {
            lastStatusMessage = "Could not move the project note."
            CrashReporter.logError("Project note move failed: \(error.localizedDescription)")
            return nil
        }
    }

    func renameProjectNote(
        projectID: String?,
        noteID: String?,
        title: String
    ) -> AssistantNotesWorkspace? {
        guard let normalizedProjectID = projectID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
              let noteID = noteID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return nil
        }
        do {
            return try projectStore.renameProjectNote(
                projectID: normalizedProjectID,
                noteID: noteID,
                title: title
            )
        } catch {
            lastStatusMessage = "Could not rename the project note."
            CrashReporter.logError("Project note rename failed: \(error.localizedDescription)")
            return nil
        }
    }

    func selectProjectNote(
        projectID: String?,
        noteID: String?
    ) -> AssistantNotesWorkspace? {
        guard let normalizedProjectID = projectID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
              let noteID = noteID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return nil
        }
        do {
            return try projectStore.selectProjectNote(
                projectID: normalizedProjectID,
                noteID: noteID
            )
        } catch {
            lastStatusMessage = "Could not switch project notes."
            CrashReporter.logError("Project note select failed: \(error.localizedDescription)")
            return nil
        }
    }

    func saveProjectNote(
        projectID: String?,
        noteID: String?,
        text: String,
        forceHistorySnapshot: Bool = false
    ) -> AssistantNotesWorkspace? {
        guard let normalizedProjectID = projectID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return nil
        }
        let normalizedNoteID = noteID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        do {
            let workspace = try projectStore.saveProjectNote(
                projectID: normalizedProjectID,
                noteID: normalizedNoteID,
                text: text,
                forceHistorySnapshot: forceHistorySnapshot
            )
            _ = try? AssistantNotesBackupController.shared.maybeRunAutomaticBackupIfNeeded()
            return workspace
        } catch {
            lastStatusMessage = "Could not save the project note."
            CrashReporter.logError("Project note save failed: \(error.localizedDescription)")
            return nil
        }
    }

    func saveProjectNoteImageAsset(
        projectID: String?,
        noteID: String?,
        attachment: AssistantAttachment
    ) -> AssistantSavedNoteAsset? {
        guard let normalizedProjectID = projectID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
              let noteID = noteID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return nil
        }

        do {
            let asset = try projectStore.saveProjectNoteImageAsset(
                projectID: normalizedProjectID,
                noteID: noteID,
                attachment: attachment
            )
            _ = try? AssistantNotesBackupController.shared.maybeRunAutomaticBackupIfNeeded()
            return asset
        } catch {
            lastStatusMessage = "Could not save that image in the project note."
            CrashReporter.logError("Project note image save failed: \(error.localizedDescription)")
            return nil
        }
    }

    func resolveProjectNoteImageAssetURL(
        projectID: String?,
        noteID: String?,
        relativePath: String
    ) -> URL? {
        guard let normalizedProjectID = projectID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
              let noteID = noteID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return nil
        }

        do {
            return try projectStore.resolveProjectNoteImageAssetURL(
                projectID: normalizedProjectID,
                noteID: noteID,
                relativePath: relativePath
            )
        } catch {
            CrashReporter.logError("Project note image resolve failed: \(error.localizedDescription)")
            return nil
        }
    }

    func deleteProjectNote(
        projectID: String?,
        noteID: String?
    ) -> AssistantNotesWorkspace? {
        guard let normalizedProjectID = projectID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
              let noteID = noteID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return nil
        }
        do {
            let workspace = try projectStore.deleteProjectNote(
                projectID: normalizedProjectID,
                noteID: noteID
            )
            _ = try? AssistantNotesBackupController.shared.maybeRunAutomaticBackupIfNeeded()
            return workspace
        } catch {
            lastStatusMessage = "Could not delete the project note."
            CrashReporter.logError("Project note delete failed: \(error.localizedDescription)")
            return nil
        }
    }

    func projectNoteHistoryVersions(
        projectID: String?,
        noteID: String?
    ) -> [AssistantNoteHistoryVersion] {
        guard let normalizedProjectID = projectID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
              let noteID = noteID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return []
        }
        return (try? projectStore.projectNoteHistoryVersions(projectID: normalizedProjectID, noteID: noteID)) ?? []
    }

    func restoreProjectNoteHistoryVersion(
        projectID: String?,
        noteID: String?,
        versionID: String?
    ) -> AssistantNotesWorkspace? {
        guard let normalizedProjectID = projectID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
              let noteID = noteID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
              let versionID = versionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return nil
        }
        do {
            let workspace = try projectStore.restoreProjectNoteHistoryVersion(
                projectID: normalizedProjectID,
                noteID: noteID,
                versionID: versionID
            )
            _ = try? AssistantNotesBackupController.shared.maybeRunAutomaticBackupIfNeeded()
            return workspace
        } catch {
            lastStatusMessage = "Could not restore that note version."
            CrashReporter.logError("Project note history restore failed: \(error.localizedDescription)")
            return nil
        }
    }

    func deleteProjectNoteHistoryVersion(
        projectID: String?,
        noteID: String?,
        versionID: String?
    ) -> AssistantNotesWorkspace? {
        guard let normalizedProjectID = projectID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
              let noteID = noteID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
              let versionID = versionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return nil
        }
        return try? projectStore.deleteProjectNoteHistoryVersion(
            projectID: normalizedProjectID,
            noteID: noteID,
            versionID: versionID
        )
    }

    func recentlyDeletedProjectNotes(projectID: String?) -> [AssistantDeletedNoteSnapshot] {
        guard let normalizedProjectID = projectID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return []
        }
        return (try? projectStore.recentlyDeletedProjectNotes(projectID: normalizedProjectID)) ?? []
    }

    func restoreDeletedProjectNote(
        projectID: String?,
        deletedNoteID: String?
    ) -> AssistantNotesWorkspace? {
        guard let normalizedProjectID = projectID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
              let deletedNoteID = deletedNoteID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return nil
        }
        do {
            let workspace = try projectStore.restoreDeletedProjectNote(
                projectID: normalizedProjectID,
                deletedNoteID: deletedNoteID
            )
            _ = try? AssistantNotesBackupController.shared.maybeRunAutomaticBackupIfNeeded()
            return workspace
        } catch {
            lastStatusMessage = "Could not restore that deleted note."
            CrashReporter.logError("Project note deleted restore failed: \(error.localizedDescription)")
            return nil
        }
    }

    func permanentlyDeleteDeletedProjectNote(
        projectID: String?,
        deletedNoteID: String?
    ) {
        guard let normalizedProjectID = projectID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
              let deletedNoteID = deletedNoteID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return
        }
        try? projectStore.permanentlyDeleteDeletedProjectNote(
            projectID: normalizedProjectID,
            deletedNoteID: deletedNoteID
        )
    }

    func appendToSelectedProjectNote(
        projectID: String?,
        text: String
    ) -> AssistantNotesWorkspace? {
        guard let normalizedProjectID = projectID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return nil
        }
        do {
            return try projectStore.appendToSelectedProjectNote(
                projectID: normalizedProjectID,
                text: text
            )
        } catch {
            lastStatusMessage = "Could not add that text to the current project note."
            CrashReporter.logError("Project note append failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func purgeExpiredArchivedSessionsIfNeeded() async {
        let expiredSessionIDs = Array(
            Set(
                sessionCatalog.expiredArchivedSessionIDs()
                    + sessionRegistry.expiredArchivedSessionIDs(
                        sources: Set([.openAssist, .cli])
                    )
            )
        )
        guard !expiredSessionIDs.isEmpty else { return }

        let knownSessions = await knownSessionsForCleanup(anchoredTo: expiredSessionIDs.first)
        let descendantSessionIDs = expiredSessionIDs.flatMap { sessionID in
            assistantChildSessionIDs(parentSessionID: sessionID, sessions: knownSessions)
        }
        let targetSessionIDs = Array(Set(expiredSessionIDs + descendantSessionIDs))

        for sessionID in targetSessionIDs {
            do {
                _ = try await destroySessionCompletely(
                    sessionID,
                    stopRuntimeIfNeeded: true
                )
            } catch {
                CrashReporter.logError("Archived session cleanup failed: \(error.localizedDescription)")
            }
        }
    }

    private func clearHistoryBranchStateForDeletedSession(_ branch: AssistantHistoryBranchState) {
        deleteHistorySnapshots(
            sessionID: branch.sessionID,
            snapshotIDs: branch.futureStates.map(\.snapshotID)
        )
        if sessionsMatch(historyBranchState?.sessionID, branch.sessionID) {
            historyBranchState = nil
        }
    }

    private func deleteSession(_ sessionID: String?, showStatusMessage: Bool) async {
        let normalizedSessionID = sessionID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? ""
        guard !normalizedSessionID.isEmpty else { return }
        if let branch = historyBranchState,
           sessionsMatch(branch.sessionID, normalizedSessionID) {
            clearHistoryBranchStateForDeletedSession(branch)
        }

        do {
            let knownSessions = await knownSessionsForCleanup(anchoredTo: normalizedSessionID)
            let descendantSessionIDs = assistantChildSessionIDs(
                parentSessionID: normalizedSessionID,
                sessions: knownSessions
            )

            var deletedAnySession = false
            for candidateSessionID in [normalizedSessionID] + descendantSessionIDs {
                let deleted = try await destroySessionCompletely(
                    candidateSessionID,
                    stopRuntimeIfNeeded: true
                )
                deletedAnySession = deletedAnySession || deleted
            }
            if showStatusMessage {
                lastStatusMessage = deletedAnySession
                    ? "Deleted the Open Assist session."
                    : "That Open Assist session was already gone."
            }
            reloadProjectsFromStore()
            refreshMemoryState(for: selectedSessionID)
            await refreshSessions()
        } catch {
            if showStatusMessage {
                lastStatusMessage = error.localizedDescription
            } else {
                CrashReporter.logError("Temporary session deletion failed: \(error.localizedDescription)")
            }
        }
    }

    func promoteTemporarySession(_ sessionID: String? = nil) {
        let targetSessionID = sessionID ?? selectedSessionID
        guard isTemporarySession(targetSessionID) else { return }
        setTemporaryFlag(false, for: targetSessionID, reportErrors: true)
        lastStatusMessage = "Kept this chat as a regular thread."
    }

    func handleAssistantWindowVisibilityChanged(_ isVisible: Bool) async {
        guard !isVisible,
              let selectedSessionID,
              isTemporarySession(selectedSessionID) else {
            return
        }
        await deleteSession(selectedSessionID, showStatusMessage: false)
    }

    func purgeTemporarySessionsForApplicationTermination() {
        let storedSessionIDs = temporarySessionIDs.sorted()
        guard !storedSessionIDs.isEmpty else { return }

        let descendantSessionIDs = storedSessionIDs.flatMap { sessionID in
            assistantChildSessionIDs(parentSessionID: sessionID, sessions: sessions)
        }

        for sessionID in Array(Set(storedSessionIDs + descendantSessionIDs)) {
            do {
                _ = try deleteSessionArtifactsLocally(sessionID)
            } catch {
                CrashReporter.logError("Temporary session cleanup on quit failed: \(error.localizedDescription)")
            }
        }

        reloadProjectsFromStore()
        sessions = applyStoredSessionMetadata(to: sessions)
    }

    @discardableResult
    private func destroySessionCompletely(
        _ sessionID: String,
        stopRuntimeIfNeeded: Bool
    ) async throws -> Bool {
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionID.isEmpty else { return false }

        markSessionPendingDeletion(normalizedSessionID)
        do {
            if stopRuntimeIfNeeded,
               let sessionRuntime = runtime(for: normalizedSessionID),
               sessionRuntime.currentSessionID?.caseInsensitiveCompare(normalizedSessionID) == .orderedSame {
                await sessionRuntime.stop()
            }
            return try deleteSessionArtifactsLocally(normalizedSessionID)
        } catch {
            deletedSessionIDs.remove(normalizedSessionID.lowercased())
            throw error
        }
    }

    @discardableResult
    private func deleteSessionArtifactsLocally(_ sessionID: String) throws -> Bool {
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionID.isEmpty else { return false }

        // Clean up checkpoint artifacts before removing session/project data
        cleanupCheckpointArtifacts(for: normalizedSessionID)

        let previousProjectID = projectStore.context(forThreadID: normalizedSessionID)?.project.id
        let deleted = try sessionCatalog.deleteSessionSynchronously(sessionID: normalizedSessionID)
        conversationStore.deleteThreadArtifacts(threadID: normalizedSessionID)
        try? threadMemoryService.clearMemory(for: normalizedSessionID)
        try? memorySuggestionService.clearSuggestions(for: normalizedSessionID)
        _ = try? projectStore.removeThreadAssignment(normalizedSessionID)
        if let previousProjectID {
            try? projectMemoryService.removeThread(normalizedSessionID, fromProjectID: previousProjectID)
        }

        removeOwnedSessionID(normalizedSessionID)
        try? sessionRegistry.remove(sessionID: normalizedSessionID)
        clearPendingFreshSession(normalizedSessionID)
        setTemporaryFlag(false, for: normalizedSessionID, reportErrors: false)
        clearActiveProposedPlanIfNeeded(for: normalizedSessionID)
        clearInMemorySessionState(for: normalizedSessionID)
        return deleted
    }

    private func cleanupCheckpointArtifacts(for sessionID: String) {
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionID.isEmpty else { return }

        // Load tracking state to get repo root path (before we delete anything)
        let trackingState = codeTrackingStateBySessionID[normalizedSessionID]
            ?? conversationCheckpointStore.loadTrackingState(for: normalizedSessionID)

        // Cancel pending checkpoint tasks
        pendingCodeCheckpointStartTasksBySessionID.removeValue(forKey: normalizedSessionID)?.cancel()
        pendingCodeCheckpointRecoveryRetryTasksBySessionID.removeValue(forKey: normalizedSessionID)?.cancel()
        pendingCodeCheckpointBaselinesBySessionID.removeValue(forKey: normalizedSessionID)
        sessionCatalogCWDCacheBySessionID.removeValue(forKey: normalizedSessionID)
        idleCodeCheckpointRecoveryAttemptedSessionIDs.remove(normalizedSessionID)

        let sessionPrefix = normalizedSessionID.lowercased() + "|"
        for (key, task) in pendingConversationCheckpointCaptureTasksByKey where key.hasPrefix(sessionPrefix) {
            task.cancel()
            pendingConversationCheckpointCaptureTasksByKey.removeValue(forKey: key)
        }

        // Clear in-memory checkpoint state
        codeTrackingStateBySessionID.removeValue(forKey: normalizedSessionID)
        if sessionsMatch(selectedCodeTrackingState?.sessionID, normalizedSessionID) {
            selectedCodeTrackingState = nil
        }
        if sessionsMatch(selectedCodeReviewPanelState?.sessionID, normalizedSessionID) {
            selectedCodeReviewPanelState = nil
        }

        // Delete tracking state files from disk (synchronous)
        conversationCheckpointStore.deleteTrackingState(for: normalizedSessionID)

        // Delete git refs asynchronously
        if let repoRootPath = trackingState?.repoRootPath {
            Task { [gitCheckpointService] in
                if let repository = try? await gitCheckpointService.repositoryContext(for: repoRootPath) {
                    await gitCheckpointService.deleteAllRefs(repository: repository, sessionID: normalizedSessionID)
                }
            }
        }
    }

    private func pruneOrphanedCheckpointArtifacts() async {
        let trackingBaseURL = conversationCheckpointStore.baseDirectoryURL
        guard let sessionDirs = try? FileManager.default.contentsOfDirectory(
            at: trackingBaseURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let knownSessions = await knownSessionsForCleanup(anchoredTo: selectedSessionID)
        var knownSessionIDs = Set(
            knownSessions.compactMap { normalizedAssistantSessionKey($0.id) }
        )
        if let selectedSessionID = normalizedAssistantSessionKey(selectedSessionID) {
            knownSessionIDs.insert(selectedSessionID)
        }

        for dirURL in sessionDirs {
            let sessionID = dirURL.lastPathComponent
            let normalizedID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalizedID.isEmpty, !knownSessionIDs.contains(normalizedID) else { continue }

            if let sessionFileURL = sessionCatalog.sessionFileURL(for: sessionID),
               FileManager.default.fileExists(atPath: sessionFileURL.path) {
                continue
            }

            // This session no longer exists — clean up its checkpoint artifacts
            if let trackingState = conversationCheckpointStore.loadTrackingState(for: sessionID),
               let repoRootPath = trackingState.repoRootPath,
               let repository = try? await gitCheckpointService.repositoryContext(for: repoRootPath) {
                await gitCheckpointService.deleteAllRefs(repository: repository, sessionID: sessionID)
            }

            conversationCheckpointStore.deleteTrackingState(for: sessionID)
            codeTrackingStateBySessionID.removeValue(forKey: sessionID)
            sessionCatalogCWDCacheBySessionID.removeValue(forKey: sessionID)
            idleCodeCheckpointRecoveryAttemptedSessionIDs.remove(sessionID)

            CrashReporter.logInfo("Pruned orphaned checkpoint artifacts for sessionID=\(sessionID)")
        }
    }

    private func clearInMemorySessionState(for sessionID: String) {
        if let normalizedSessionID = normalizedSessionID(sessionID) {
            sessionExecutionStateBySessionID.removeValue(forKey: normalizedSessionID)
            if let runtime = sessionRuntimesBySessionID.removeValue(forKey: normalizedSessionID) {
                clearRuntimeCallbacks(runtime)
                Task { await runtime.stop() }
            }
        }
        sessionCatalogCWDCacheBySessionID.removeValue(forKey: sessionID)
        idleCodeCheckpointRecoveryAttemptedSessionIDs.remove(sessionID)
        if sessionsMatch(selectedSessionID, sessionID) {
            sessionLoadRequestID = UUID()
            selectedSessionID = nil
            setVisibleTimeline([], for: nil)
            setVisibleTranscript([], for: nil)
            planEntries = []
            toolCalls = []
            recentToolCalls = []
            pendingPermissionRequest = nil
        } else {
            if sessionsMatch(timelineSessionID, sessionID) {
                setVisibleTimeline([], for: nil)
            }
            if sessionsMatch(transcriptSessionID, sessionID) {
                setVisibleTranscript([], for: nil)
            }
            let pendingPermissionThreadID =
                canonicalThreadID(forProviderSessionID: pendingPermissionRequest?.sessionID)
                ?? pendingPermissionRequest?.sessionID
            if sessionsMatch(pendingPermissionThreadID, sessionID) {
                pendingPermissionRequest = nil
            }
        }

        pendingTimelineCacheSaveWorkItems[sessionID]?.cancel()
        pendingTimelineCacheSaveWorkItems.removeValue(forKey: sessionID)
        pendingResumeContextSnapshotsBySessionID.removeValue(forKey: sessionID)
        pendingResumeContextMetadataBySessionID.removeValue(forKey: sessionID)
        transcriptEntriesBySessionID.removeValue(forKey: sessionID)
        timelineItemsBySessionID.removeValue(forKey: sessionID)
        requestedTimelineHistoryLimitBySessionID.removeValue(forKey: sessionID)
        requestedTranscriptHistoryLimitBySessionID.removeValue(forKey: sessionID)
        canLoadMoreHistoryBySessionID.removeValue(forKey: sessionID)
        editableTurnsBySessionID.removeValue(forKey: sessionID)
        subagents.removeAll {
            sessionsMatch($0.parentThreadID, sessionID) || sessionsMatch($0.threadID, sessionID)
        }
        sessions.removeAll { sessionsMatch($0.id, sessionID) }
        persistManagedSessionsSnapshot()
    }

    private func cleanupTemporarySessionAfterLeaving(
        _ previousSelectedSessionID: String?,
        nextSelectedSessionID: String?
    ) async {
        guard let previousSelectedSessionID,
              isTemporarySession(previousSelectedSessionID),
              !sessionsMatch(previousSelectedSessionID, nextSelectedSessionID) else {
            return
        }
        await deleteSession(previousSelectedSessionID, showStatusMessage: false)
    }

    private func knownSessionsForCleanup(anchoredTo preferredSessionID: String?) async -> [AssistantSessionSummary] {
        let liveSessions = applyStoredSessionMetadata(to: sessions)
        var catalogSessions: [AssistantSessionSummary] = []

        do {
            let loadedSessions = try await sessionCatalog.loadSessions(
                limit: max(200, sessions.count + settings.assistantOwnedThreadIDs.count + temporarySessionIDs.count + 20),
                preferredThreadID: preferredSessionID,
                preferredCWD: nil,
                originatorFilter: "Open Assist"
            )
            catalogSessions = applyStoredSessionMetadata(to: loadedSessions)
        } catch {
            CrashReporter.logError("Known session cleanup scope load failed: \(error.localizedDescription)")
        }

        let registrySessions = applyStoredSessionMetadata(
            to: sessionRegistry.sessions(sources: [.openAssist])
        )

        return assistantMergedSessionsForCleanup(
            liveSessions: liveSessions,
            catalogSessions: catalogSessions,
            registrySessions: registrySessions
        )
    }

    private func purgeStoredTemporarySessionsOnLaunch() async {
        let storedSessionIDs = temporarySessionIDs.sorted()
        guard !storedSessionIDs.isEmpty else { return }

        let knownSessions = await knownSessionsForCleanup(anchoredTo: storedSessionIDs.first)
        let descendantSessionIDs = storedSessionIDs.flatMap { sessionID in
            assistantChildSessionIDs(parentSessionID: sessionID, sessions: knownSessions)
        }

        for sessionID in Array(Set(storedSessionIDs + descendantSessionIDs)) {
            do {
                _ = try deleteSessionArtifactsLocally(sessionID)
            } catch {
                CrashReporter.logError("Temporary session cleanup on launch failed: \(error.localizedDescription)")
            }
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
            persistManagedSessionsSnapshot()
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
        if let branch = historyBranchState {
            clearHistoryBranchStateForDeletedSession(branch)
        }

        do {
            for sessionID in ownedSessionIDs {
                if let sessionRuntime = runtime(for: sessionID),
                   sessionRuntime.currentSessionID?.caseInsensitiveCompare(sessionID) == .orderedSame {
                    await sessionRuntime.stop()
                }
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
        if let request = pendingPermissionRequest {
            await prepareTrackedCodeCheckpointIfNeeded(
                for: request,
                optionID: optionID
            )
        }
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

    /// Strip heavy imageAttachments data from screenshot timeline items that have
    /// already been delivered to Telegram, keeping the text/metadata intact.
    /// This prevents screenshots from accumulating on disk in session history.
    func clearDeliveredScreenshotAttachments(sessionID: String? = nil) {
        guard let sessionID = sessionID ?? selectedSessionID else { return }

        var mutated = false
        let items: [AssistantTimelineItem]
        if sessionsMatch(timelineSessionID, sessionID) {
            items = timelineItems
        } else {
            items = timelineItemsBySessionID[sessionID] ?? []
        }

        var cleaned = items
        for index in cleaned.indices {
            guard cleaned[index].kind == .system,
                  cleaned[index].imageAttachments?.isEmpty == false,
                  cleaned[index].id.hasPrefix("tool-screenshot-") else { continue }
            cleaned[index].imageAttachments = nil
            mutated = true
        }

        guard mutated else { return }
        if sessionsMatch(timelineSessionID, sessionID) {
            timelineItems = cleaned
        } else {
            timelineItemsBySessionID[sessionID] = cleaned
        }
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
            AssistantWorkspaceFileOpener.openFileURL(fileURL)
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

    func inspectCurrentMemory() {
        if let selectedSession {
            inspectMemory(for: selectedSession)
            return
        }

        if let runtimeSessionID = activeRuntimeSessionID,
           let runtimeSession = sessions.first(where: { sessionsMatch($0.id, runtimeSessionID) }) {
            inspectMemory(for: runtimeSession)
            return
        }

        lastStatusMessage = "Open a chat thread first."
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

    func requestSelectionSideAssistantReply(
        _ selectedText: String,
        in parentMessageText: String,
        question: String,
        backend overrideBackend: AssistantRuntimeBackend? = nil,
        preferredModelID overrideModelID: String? = nil,
        mainChatSummary overrideMainChatSummary: String? = nil,
        conversationHistory: [SelectionAskConversationTurn] = [],
        onPartialText: (@Sendable (String) -> Void)? = nil
    ) async -> MemoryEntryExplanationResult {
        let normalizedSelection = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSelection.isEmpty else {
            return .failure("Select some text first.")
        }

        let normalizedParentMessage = parentMessageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedParentMessage.isEmpty else {
            return .failure("Could not find the full message for this selection.")
        }

        let normalizedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuestion.isEmpty else {
            return .failure("Ask a question first.")
        }

        let backend = overrideBackend ?? visibleAssistantBackend
        let installGuidance = await installSupport.inspect(backend: backend)
        guard installGuidance.codexDetected else {
            return .failure(installGuidance.primaryDetail)
        }

        let availableModels = selectionSideAssistantVisibleModels(for: backend)
        let resolvedModels = availableModels.isEmpty
            ? await loadSelectionSideAssistantVisibleModels(for: backend)
            : availableModels
        let inheritedPreferredModelID: String? = {
            if let overrideModelID {
                return overrideModelID
            }
            return backend == visibleAssistantBackend ? selectedModelID : nil
        }()

        let preferredModelID = Self.resolvedModelSelection(
            from: nil,
            backend: backend,
            availableModels: resolvedModels,
            preferredModelID: inheritedPreferredModelID,
            surfaceModelID: nil
        )
        guard let preferredModelID else {
            return .failure("Choose a model before using the side assistant.")
        }

        let mainChatSummary = overrideMainChatSummary?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
            ?? selectionSideAssistantChatSummarySnapshot()?.summary

        if backend == .codex {
            CrashReporter.logInfo(
                "Selection side assistant direct request started backend=\(backend.rawValue) requestedModel=\(inheritedPreferredModelID ?? "none") resolvedModel=\(preferredModelID) historyTurns=\(conversationHistory.count) selectionChars=\(normalizedSelection.count) questionChars=\(normalizedQuestion.count) mainChatSummaryChars=\(mainChatSummary?.count ?? 0)"
            )

            if let directResult = await MemoryEntryExplanationService.shared.explainSelectedTextDirectIfAvailable(
                normalizedSelection,
                parentMessageText: normalizedParentMessage,
                question: normalizedQuestion,
                preferredProviderMode: .openAI,
                preferredModel: preferredModelID,
                conversationHistory: conversationHistory,
                wholeChatSummary: mainChatSummary,
                onPartialText: onPartialText
            ) {
                switch directResult {
                case .success(let responseText):
                    CrashReporter.logInfo(
                        "Selection side assistant direct request completed backend=\(backend.rawValue) model=\(preferredModelID) responseChars=\(responseText.count)"
                    )
                case .failure(let message):
                    CrashReporter.logWarning(
                        "Selection side assistant direct request failed backend=\(backend.rawValue) model=\(preferredModelID) message=\(message)"
                    )
                }
                return directResult
            }

            CrashReporter.logInfo(
                "Selection side assistant direct request unavailable backend=\(backend.rawValue) model=\(preferredModelID); falling back to runtime"
            )
        }

        let prompt = SelectionAskPromptBuilder.makePrompt(
            selectedText: normalizedSelection,
            parentMessageText: normalizedParentMessage,
            question: normalizedQuestion,
            conversationHistory: conversationHistory,
            wholeChatSummary: mainChatSummary
        )

        CrashReporter.logInfo(
            "Selection side assistant request started backend=\(backend.rawValue) requestedModel=\(inheritedPreferredModelID ?? "none") resolvedModel=\(preferredModelID) historyTurns=\(conversationHistory.count) selectionChars=\(normalizedSelection.count) questionChars=\(normalizedQuestion.count) mainChatSummaryChars=\(mainChatSummary?.count ?? 0)"
        )

        let selectedSessionID = selectedSessionID ?? runtime.currentSessionID
        let resolvedCWD = selectedSessionID.flatMap { resolvedSessionCWD(for: $0) }
        let selectedReasoningEffort = backend == .codex ? AssistantReasoningEffort.low.wireValue : nil
        let selectedServiceTier = backend == .codex ? "fast" : nil
        let selectedInteractionMode: AssistantInteractionMode = .conversational

        let temporaryRuntime = CodexAssistantRuntime(preferredModelID: preferredModelID)
        temporaryRuntime.backend = backend
        temporaryRuntime.interactionMode = selectedInteractionMode
        temporaryRuntime.reasoningEffort = selectedReasoningEffort
        temporaryRuntime.serviceTier = selectedServiceTier
        temporaryRuntime.activeSkills = []
        temporaryRuntime.customInstructions = """
        \(prompt.systemPrompt)

        This is an internal side-assistant turn inside Open Assist.
        Do not use tools, browse the web, open apps, run commands, edit files, or ask for permissions.
        Answer directly from the supplied chat context and question.
        """

        let recorder = SelectionSideAssistantResponseRecorder()

        let result: MemoryEntryExplanationResult = await withCheckedContinuation { continuation in
            let continuationBox = SelectionSideAssistantContinuationBox(continuation)
            let timeoutTask = Task {
                do {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                } catch {
                    return
                }
                continuationBox.resume(.failure("The side assistant took too long to reply. Please try again."))
                await temporaryRuntime.cancelPendingPermissionRequest()
                await temporaryRuntime.cancelActiveTurn()
            }

            temporaryRuntime.onTranscriptMutation = { mutation in
                recorder.record(mutation)
                if let partialText = recorder.latestAssistantText()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty {
                    onPartialText?(partialText)
                }
            }

            temporaryRuntime.onPermissionRequest = { _ in
                Task { @MainActor in
                    await temporaryRuntime.cancelPendingPermissionRequest()
                    await temporaryRuntime.cancelActiveTurn()
                }
            }

            temporaryRuntime.onTurnCompletion = { status in
                timeoutTask.cancel()
                let finalText = recorder.latestAssistantText()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty

                switch status {
                case .completed:
                    if let finalText {
                        continuationBox.resume(.success(finalText))
                    } else {
                        continuationBox.resume(.failure("The side assistant returned an empty answer."))
                    }
                case .interrupted:
                    if let finalText {
                        continuationBox.resume(.success(finalText))
                    } else {
                        continuationBox.resume(.failure("The side assistant stopped before it finished."))
                    }
                case .failed(let message):
                    if let finalText {
                        continuationBox.resume(.success(finalText))
                    } else {
                        continuationBox.resume(.failure(message))
                    }
                }
            }

            Task { @MainActor in
                do {
                    _ = try await temporaryRuntime.startNewSession(
                        cwd: resolvedCWD,
                        preferredModelID: preferredModelID
                    )
                    try await temporaryRuntime.sendPrompt(
                        prompt.userPrompt,
                        attachments: [],
                        preferredModelID: preferredModelID,
                        modelSupportsImageInput: true,
                        resumeContext: nil,
                        memoryContext: nil
                    )
                } catch {
                    timeoutTask.cancel()
                    let errorMessage = error.localizedDescription.localizedCaseInsensitiveContains("did not answer")
                        ? "\(backend.displayName) did not answer the Ask request in time. Please try again."
                        : error.localizedDescription
                    continuationBox.resume(.failure(errorMessage))
                }
            }
        }

        Task { @MainActor in
            await temporaryRuntime.stop()
        }

        switch result {
        case .success(let responseText):
            CrashReporter.logInfo(
                "Selection side assistant request completed backend=\(backend.rawValue) model=\(preferredModelID) responseChars=\(responseText.count)"
            )
        case .failure(let message):
            CrashReporter.logWarning(
                "Selection side assistant request failed backend=\(backend.rawValue) model=\(preferredModelID) message=\(message)"
            )
        }

        return result
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

    func selectionSideAssistantChatSummarySnapshot() -> SelectionSideAssistantChatSummarySnapshot? {
        let targetSessionID = selectedSessionID ?? runtime.currentSessionID
        let sessionTranscript = targetSessionID.flatMap { transcriptEntriesBySessionID[$0] } ?? transcript
        let sessionSummary = targetSessionID.flatMap { sessionID in
            sessions.first(where: { sessionsMatch($0.id, sessionID) })
        }

        return SelectionSideAssistantChatSummaryBuilder.build(
            sessionID: targetSessionID ?? "active-thread",
            sessionTitle: sessionSummary?.title,
            sessionSummary: sessionSummary?.summary
                ?? sessionSummary?.latestAssistantMessage
                ?? sessionSummary?.latestUserMessage,
            transcriptEntries: sessionTranscript
        )
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
        if visibleAssistantBackend == .ollamaLocal {
            openLocalAISetup(preferredModelID: selectedModelID ?? AssistantGemma4ModelCatalog.recommendedModelID())
            return
        }
        guard let command = installGuidance.installCommands.first else { return }
        runInTerminal(command)
    }

    func runPreferredInstallCommand(for backend: AssistantRuntimeBackend) {
        if backend == .ollamaLocal {
            openLocalAISetup(preferredModelID: AssistantGemma4ModelCatalog.recommendedModelID())
            return
        }
        guard let command = guidance(for: backend).installCommands.first else { return }
        runInTerminal(command)
    }

    private func openLocalAISetup(preferredModelID: String?) {
        AIStudioNavigationState.shared.requestOpen(
            pageRawValue: "models",
            preferredLocalModelID: preferredModelID
        )
        NotificationCenter.default.post(name: .openAssistOpenAIMemoryStudio, object: nil)
    }

    func runLoginCommand() {
        startAccountLogin()
    }

    func openInstallDocs() {
        guard let docsURL = installGuidance.docsURL else { return }
        NSWorkspace.shared.open(docsURL)
    }

    func openInstallDocs(for backend: AssistantRuntimeBackend) {
        guard let docsURL = guidance(for: backend).docsURL else { return }
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
        syncRuntimeContext()
    }

    private func applyCurrentRuntimeContext(
        to targetRuntime: CodexAssistantRuntime,
        threadID: String?
    ) {
        targetRuntime.activeSkills = resolvedActiveSkillDescriptors(for: threadID)
        targetRuntime.browserProfileContext = currentBrowserProfileContext

        let usesSelectedSessionContext = sessionsMatch(threadID, selectedSessionID)
        let notesRuntimeContext = usesSelectedSessionContext ? activeAssistantNotesRuntimeContext() : nil

        let global = settings.assistantCustomInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let session = usesSelectedSessionContext
            ? sessionInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        let oneShot = usesSelectedSessionContext
            ? oneShotSessionInstructions?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            : ""
        let contextualInstructions = notesRuntimeContext?.instructionText
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let mergedOneShot = [oneShot, contextualInstructions]
            .compactMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty }
            .joined(separator: "\n\n")

        targetRuntime.customInstructions = Self.combinedRuntimeInstructions(
            global: global,
            session: session,
            oneShot: mergedOneShot
        )
        targetRuntime.assistantNotesContext = notesRuntimeContext
        targetRuntime.setPreferredSubagentModelID(selectedSubagentModelID)
        targetRuntime.reasoningEffort = reasoningEffort.wireValue
        targetRuntime.serviceTier = fastModeEnabled ? "fast" : nil
        targetRuntime.interactionMode = interactionMode
        targetRuntime.maxToolCallsPerTurn = settings.assistantMaxToolCallsPerTurn
        targetRuntime.maxRepeatedCommandAttemptsPerTurn = settings.assistantMaxRepeatedCommandAttemptsPerTurn
    }

    func requestBrowserProfileSelection() {
        showBrowserProfilePicker = true
    }

    func syncRuntimeContext() {
        applyCurrentRuntimeContext(to: runtime, threadID: selectedSessionID)
        if !isRestoringSessionConfiguration {
            updateVisibleSessionConfiguration()
        }
    }

    func setNotesWorkspaceRuntimeContext(_ context: AssistantNotesRuntimeContext?) {
        if notesWorkspaceRuntimeContext == context {
            return
        }
        notesWorkspaceRuntimeContext = context
        syncRuntimeContext()
    }

    private func activeAssistantNotesRuntimeContext() -> AssistantNotesRuntimeContext? {
        if let notesWorkspaceRuntimeContext {
            return notesWorkspaceRuntimeContext
        }

        guard taskMode == .note else {
            return nil
        }

        if let sessionID = selectedSessionID,
           let context = projectStore.context(forThreadID: sessionID) {
            return AssistantNotesRuntimeContext(
                source: .chatNoteMode,
                projectID: context.project.id,
                projectName: context.project.name,
                selectedNoteTarget: nil,
                selectedNoteTitle: nil,
                defaultScopeDescription: "the whole current project (`\(context.project.name)`) including project notes and linked thread notes"
            )
        }

        if let selectedProject {
            return AssistantNotesRuntimeContext(
                source: .chatNoteMode,
                projectID: selectedProject.id,
                projectName: selectedProject.name,
                selectedNoteTarget: nil,
                selectedNoteTitle: nil,
                defaultScopeDescription: "the whole current project (`\(selectedProject.name)`) including project notes and linked thread notes"
            )
        }

        return nil
    }

    private func refreshActiveThreadSkills(syncRuntime: Bool) {
        guard let normalizedThreadID = selectedSessionID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty else {
            if !activeThreadSkills.isEmpty {
                activeThreadSkills = []
            }
            if syncRuntime {
                syncRuntimeContext()
            }
            return
        }

        let descriptorsByName = Dictionary(
            uniqueKeysWithValues: availableSkills.map { ($0.name, $0) }
        )
        activeThreadSkills = threadSkillStore.bindings(for: normalizedThreadID).map { binding in
            AssistantThreadSkillState(
                binding: binding,
                descriptor: descriptorsByName[binding.skillName]
            )
        }

        if syncRuntime {
            syncRuntimeContext()
        }
    }

    private func resolvedActiveSkillDescriptors(for threadID: String?) -> [AssistantSkillDescriptor] {
        guard let normalizedThreadID = threadID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return []
        }

        let descriptorsByName = Dictionary(
            uniqueKeysWithValues: availableSkills.map { ($0.name, $0) }
        )

        return threadSkillStore.bindings(for: normalizedThreadID).compactMap { binding in
            descriptorsByName[binding.skillName]
        }
    }

    private func refreshCurrentSessionConfigurationForModeChange() async {
        let selectedRuntime = runtime(for: selectedSessionID) ?? runtime
        guard !selectedRuntime.hasActiveTurn,
              let sessionID = selectedRuntime.currentSessionID?.nonEmpty else {
            return
        }

        guard !isPendingFreshSession(sessionID) else {
            return
        }

        try? await selectedRuntime.refreshCurrentSessionConfiguration(
            cwd: resolvedSessionCWD(for: sessionID),
            preferredModelID: selectedModelID
        )
    }

    private func applyPreferredModelSelection(using models: [AssistantModelOption]) {
        let visibleModels = Self.selectableModels(for: visibleAssistantBackend, from: models)
        guard !visibleModels.isEmpty else {
            selectedModelID = nil
            selectedSubagentModelID = nil
            runtime.setPreferredModelID(nil)
            runtime.setPreferredSubagentModelID(nil)
            runtimeHealth.selectedModelID = nil
            return
        }

        let resolvedModelID = Self.resolvedModelSelection(
            from: selectedSession,
            backend: visibleAssistantBackend,
            availableModels: models,
            preferredModelID: settings.assistantPreferredModelID.nonEmpty,
            surfaceModelID: providerSurfaceSnapshot(
                threadID: selectedSession?.id,
                backend: visibleAssistantBackend
            )?.selectedModelID
        )
        selectedModelID = resolvedModelID
        runtime.setPreferredModelID(resolvedModelID)
        runtimeHealth.selectedModelID = resolvedModelID

        let storedSubagentModelID = settings.assistantPreferredSubagentModelID.nonEmpty
        let resolvedSubagentModelID: String?
        if let storedSubagentModelID,
           visibleModels.contains(where: { $0.id == storedSubagentModelID }) {
            resolvedSubagentModelID = storedSubagentModelID
        } else {
            resolvedSubagentModelID = nil
        }

        if let resolvedSubagentModelID {
            if settings.assistantPreferredSubagentModelID != resolvedSubagentModelID {
                settings.assistantPreferredSubagentModelID = resolvedSubagentModelID
            }
        } else if !settings.assistantPreferredSubagentModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            settings.assistantPreferredSubagentModelID = ""
        }

        selectedSubagentModelID = resolvedSubagentModelID
        runtime.setPreferredSubagentModelID(resolvedSubagentModelID)
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

        if !canStartConversation,
           !isRefreshingEnvironment,
           (isLoadingModels || visibleModels.isEmpty || selectedModel == nil) {
            CrashReporter.logInfo("Assistant auto-refreshing provider models before send backend=\(visibleAssistantBackend.rawValue)")
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
            // Keep sidebar recency tied to real message activity.
            // Simply selecting or resurfacing a thread should not make it look newly updated.
            sessions[existingIndex].latestModel = selectedModelID
            sessions[existingIndex].latestTaskMode = taskMode
            sessions[existingIndex].latestInteractionMode = interactionMode
            sessions[existingIndex].latestReasoningEffort = reasoningEffort
            sessions[existingIndex].latestServiceTier = fastModeEnabled ? "fast" : nil
            if let lastSubmittedPrompt {
                sessions[existingIndex].latestUserMessage = lastSubmittedPrompt
                if Self.shouldApplyPromptDerivedSessionTitle(
                    existingTitle: sessions[existingIndex].title,
                    fallbackTitle: Self.sessionTitle(from: lastSubmittedPrompt),
                    cwd: sessions[existingIndex].cwd ?? ""
                ) {
                    sessions[existingIndex].title = Self.sessionTitle(from: lastSubmittedPrompt)
                }
            }
            return
        }

        let title = lastSubmittedPrompt.map(Self.sessionTitle(from:)) ?? "New Assistant Session"
        let summary = AssistantSessionSummary(
            id: sessionID,
            title: title,
            source: assistantBackend.sessionSource,
            status: Self.normalizedFreshSessionStatus(
                currentStatus: .active,
                hasConversationContent: lastSubmittedPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty != nil,
                hasActiveTurn: runtime.hasActiveTurn
            ),
            cwd: runtime.currentSessionCWD,
            createdAt: Date(),
            updatedAt: Date(),
            summary: lastSubmittedPrompt,
            latestModel: selectedModelID,
            latestTaskMode: taskMode,
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
        let sanitized = cleaned.hasPrefix("# Session Memory") ? "New Assistant Session" : cleaned

        // Try to extract the first sentence
        let sentenceEnders: [Character] = [".", "?", "!"]
        if let endIndex = sanitized.firstIndex(where: { sentenceEnders.contains($0) }) {
            let sentence = String(sanitized[sanitized.startIndex...endIndex])
            if sentence.count >= 8 && sentence.count <= 80 {
                return sentence
            }
        }

        // Truncate to ~60 chars at a word boundary
        if sanitized.count <= 60 { return sanitized }
        let prefix = String(sanitized.prefix(60))
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
        shouldApplyPromptDerivedSessionTitle(
            existingTitle: existingTitle,
            fallbackTitle: fallbackTitle,
            cwd: cwd
        )
    }

    static func shouldApplyPromptDerivedSessionTitle(
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
        deletedSessionIDs.remove(sessionID.lowercased())
        settings.assistantOwnedThreadIDs = Self.updatedOwnedSessionIDs(
            existing: settings.assistantOwnedThreadIDs,
            adding: sessionID
        )
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
            guard !deletedSessionIDs.contains(normalized) else { continue }
            if seen.insert(normalized).inserted {
                ordered.append(trimmed)
            }
        }

        if let currentSessionID = managedSessionID(for: runtime) {
            let normalized = currentSessionID.lowercased()
            if !deletedSessionIDs.contains(normalized),
               seen.insert(normalized).inserted {
                ordered.insert(currentSessionID, at: 0)
            }
        }

        if let selectedSessionID = selectedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            let normalized = selectedSessionID.lowercased()
            if !deletedSessionIDs.contains(normalized),
               seen.insert(normalized).inserted {
                ordered.insert(selectedSessionID, at: 0)
            }
        }

        return ordered
    }

    private func appendTranscriptEntry(_ entry: AssistantTranscriptEntry, sessionID: String? = nil) {
        let targetSessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? selectedSessionID
        let annotatedEntry = annotatedTranscriptEntry(entry, sessionID: targetSessionID)

        guard sessionsMatch(targetSessionID, selectedSessionID) || transcriptSessionID == nil else {
            storeTranscriptEntryInCache(annotatedEntry, sessionID: targetSessionID)
            updateVisibleSessionPreview(with: annotatedEntry, sessionID: targetSessionID)
            return
        }

        if transcriptSessionID == nil {
            transcriptSessionID = targetSessionID
        }

        if let existingIndex = transcript.lastIndex(where: { $0.id == annotatedEntry.id }) {
            transcript[existingIndex] = annotatedEntry
        } else {
            transcript.append(annotatedEntry)
        }
        if let targetSessionID {
            transcriptEntriesBySessionID[targetSessionID] = transcript
            recordConversationMutationIfNeeded(sessionID: targetSessionID) { normalizedSessionID in
                try self.conversationStore.appendTranscriptUpsertEvent(
                    threadID: normalizedSessionID,
                    entry: annotatedEntry
                )
            }
        }
        updateVisibleSessionPreview(with: annotatedEntry, sessionID: targetSessionID)

        if annotatedEntry.role == .assistant,
           !annotatedEntry.isStreaming,
           let sessionID = targetSessionID,
           let text = annotatedEntry.text.assistantNonEmpty {
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
            recordConversationMutationIfNeeded(
                sessionID: normalizedSessionID,
                forceSnapshotFlush: true
            ) { normalizedSessionID in
                try self.conversationStore.appendTranscriptResetEvent(threadID: normalizedSessionID)
            }

        case .upsert(let entry, let sessionID):
            appendTranscriptEntry(entry, sessionID: sessionID)

        case .appendDelta(let id, let sessionID, let role, let delta, let createdAt, let emphasis, let isStreaming):
            guard let normalizedDelta = delta.streamingDeltaPreservingWhitespace else { return }
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
                    isStreaming: isStreaming,
                    providerBackend: existingEntry.providerBackend,
                    providerModelID: existingEntry.providerModelID
                )
            } else {
                transcript.append(
                    annotatedTranscriptEntry(
                        AssistantTranscriptEntry(
                            id: id,
                            role: role,
                            text: normalizedDelta,
                            createdAt: createdAt,
                            emphasis: emphasis,
                            isStreaming: isStreaming
                        ),
                        sessionID: targetSessionID
                    )
                )
            }

            if let targetSessionID {
                transcriptEntriesBySessionID[targetSessionID] = transcript
                let updatedEntry = transcript.last(where: { $0.id == id })
                recordConversationMutationIfNeeded(sessionID: targetSessionID) { normalizedSessionID in
                    try self.conversationStore.appendTranscriptAppendDeltaEvent(
                        threadID: normalizedSessionID,
                        id: id,
                        role: role,
                        delta: normalizedDelta,
                        createdAt: updatedEntry?.createdAt ?? createdAt,
                        emphasis: emphasis,
                        isStreaming: isStreaming,
                        providerBackend: updatedEntry?.providerBackend,
                        providerModelID: updatedEntry?.providerModelID
                    )
                }
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

            clearPendingSendState(for: normalizedSessionID)
            timelineItemsBySessionID[normalizedSessionID] = []
            if sessionsMatch(timelineSessionID, normalizedSessionID) || sessionsMatch(selectedSessionID, normalizedSessionID) {
                setVisibleTimeline([], for: normalizedSessionID)
            }
            if isProviderIndependentThreadV2(sessionID: normalizedSessionID) {
                recordConversationMutationIfNeeded(
                    sessionID: normalizedSessionID,
                    forceSnapshotFlush: true
                ) { normalizedSessionID in
                    try self.conversationStore.appendTimelineResetEvent(threadID: normalizedSessionID)
                }
            } else {
                persistTimelineCacheIfNeeded(sessionID: normalizedSessionID, items: [], force: true)
            }

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
            if isProviderIndependentThreadV2(sessionID: targetSessionID) {
                recordConversationMutationIfNeeded(
                    sessionID: targetSessionID,
                    forceSnapshotFlush: true
                ) { normalizedSessionID in
                    try self.conversationStore.appendTimelineRemoveEvent(
                        threadID: normalizedSessionID,
                        id: id
                    )
                }
            } else {
                persistTimelineCacheIfNeeded(sessionID: targetSessionID, items: items, force: true)
            }

        case .upsert(let item):
            let targetSessionID = item.sessionID?.nonEmpty
                ?? runtime.currentSessionID?.nonEmpty
                ?? selectedSessionID?.nonEmpty
            let annotatedItem = annotatedTimelineItem(item, sessionID: targetSessionID)

            switch annotatedItem.kind {
            case .userMessage:
                clearPendingOutgoingMessage(for: targetSessionID)
            case .assistantProgress, .assistantFinal, .activity, .permission, .plan:
                clearAwaitingAssistantStart(for: targetSessionID)
            case .system:
                break
            }

            let previousVisibleItems = timelineItems
            var items = targetSessionID.flatMap { timelineItemsBySessionID[$0] }
                ?? (sessionsMatch(timelineSessionID, targetSessionID) ? timelineItems : [])
            let existingItem = items.first(where: { $0.id == annotatedItem.id })

            if let existingIndex = items.firstIndex(where: { $0.id == annotatedItem.id }) {
                items[existingIndex] = annotatedItem
            } else {
                items.append(annotatedItem)
            }

            sortTimelineItems(&items)

            if let targetSessionID {
                timelineItemsBySessionID[targetSessionID] = items
                recordConversationMutationIfNeeded(sessionID: targetSessionID) { normalizedSessionID in
                    try self.conversationStore.appendTimelineUpsertEvent(
                        threadID: normalizedSessionID,
                        item: annotatedItem
                    )
                }
                if sessionsMatch(selectedSessionID, targetSessionID) || sessionsMatch(timelineSessionID, targetSessionID) {
                    if !applyVisibleTimelineTailUpdateIfPossible(
                        previousItems: previousVisibleItems,
                        updatedItems: items,
                        updatedItem: annotatedItem,
                        sessionID: targetSessionID
                    ) {
                        setVisibleTimeline(items, for: targetSessionID)
                    }
                }
                if !isProviderIndependentThreadV2(sessionID: targetSessionID),
                   annotatedItem.cacheable || existingItem?.cacheable == true {
                    persistTimelineCacheIfNeeded(
                        sessionID: targetSessionID,
                        items: items,
                        force: shouldForceTimelineCachePersistence(for: annotatedItem)
                    )
                }
            } else {
                timelineItems = items
                rebuildRenderItemsCache()
            }

            maybeSpeakAssistantFinal(annotatedItem, existingItem: existingItem)

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
            guard let normalizedDelta = delta.streamingDeltaPreservingWhitespace else { return }
            let targetSessionID = sessionID?.nonEmpty
                ?? runtime.currentSessionID?.nonEmpty
                ?? selectedSessionID?.nonEmpty

            switch kind {
            case .userMessage:
                clearPendingOutgoingMessage(for: targetSessionID)
            case .assistantProgress, .assistantFinal, .plan:
                clearAwaitingAssistantStart(for: targetSessionID)
            case .activity, .permission, .system:
                break
            }

            let previousVisibleItems = timelineItems
            var items = targetSessionID.flatMap { timelineItemsBySessionID[$0] }
                ?? (sessionsMatch(timelineSessionID, targetSessionID) ? timelineItems : [])

            if let existingIndex = items.firstIndex(where: { $0.id == id }) {
                items[existingIndex].updatedAt = updatedAt
                items[existingIndex].isStreaming = isStreaming
                items[existingIndex].emphasis = items[existingIndex].emphasis || emphasis
                if items[existingIndex].providerBackend == nil,
                   let normalizedTargetSessionID = normalizedSessionID(targetSessionID),
                   let session = sessions.first(where: { sessionsMatch($0.id, normalizedTargetSessionID) }) {
                    items[existingIndex].providerBackend = session.activeProviderBackend
                    items[existingIndex].providerModelID = session.modelID ?? selectedModelID
                }

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
                        selectedPlugins: nil,
                        source: source
                    )
                case .activity, .permission:
                    return
                }

                items.append(annotatedTimelineItem(newItem, sessionID: targetSessionID))
                sortTimelineItems(&items)
            }

            if let targetSessionID {
                timelineItemsBySessionID[targetSessionID] = items
                let updatedItem = items.first(where: { $0.id == id })
                recordConversationMutationIfNeeded(sessionID: targetSessionID) { normalizedSessionID in
                    try self.conversationStore.appendTimelineAppendTextDeltaEvent(
                        threadID: normalizedSessionID,
                        id: id,
                        turnID: updatedItem?.turnID ?? turnID,
                        kind: kind,
                        delta: normalizedDelta,
                        createdAt: updatedItem?.createdAt ?? createdAt,
                        updatedAt: updatedItem?.updatedAt ?? updatedAt,
                        isStreaming: isStreaming,
                        emphasis: emphasis,
                        source: updatedItem?.source ?? source,
                        providerBackend: updatedItem?.providerBackend,
                        providerModelID: updatedItem?.providerModelID
                    )
                }
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

    private func updateToolCallActivity(
        _ calls: [AssistantToolCallState],
        sessionID: String? = nil
    ) {
        let targetSessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? runtime.currentSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? selectedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let currentState = normalizedSessionID(targetSessionID).flatMap {
            sessionExecutionStateBySessionID[$0]
        } ?? AssistantSessionExecutionState()
        let incomingIDs = Set(calls.map(\.id))
        let completedCalls = currentState.toolCalls
            .filter { !incomingIDs.contains($0.id) }
            .map(Self.archivedToolCall(from:))
        var recentCalls = currentState.recentToolCalls

        if !completedCalls.isEmpty {
            let completedIDs = Set(completedCalls.map(\.id))
            recentCalls.removeAll { completedIDs.contains($0.id) || incomingIDs.contains($0.id) }
            recentCalls.insert(contentsOf: completedCalls, at: 0)
            if recentCalls.count > 24 {
                recentCalls = Array(recentCalls.prefix(24))
            }
        } else if !incomingIDs.isEmpty {
            recentCalls.removeAll { incomingIDs.contains($0.id) }
        }

        withSessionExecutionState(for: targetSessionID) { state in
            state.toolCalls = calls
            state.recentToolCalls = recentCalls
            if !incomingIDs.isEmpty {
                state.awaitingAssistantStart = false
            }
        }

        let shouldPrimeTrackedCodeCheckpoint = calls.contains { call in
            guard let kind = call.kind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  kind == "commandexecution" || kind == "filechange" else {
                return false
            }

            let normalizedStatus = call.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !["completed", "failed", "cancelled", "canceled", "interrupted"].contains(normalizedStatus)
        }

        if shouldPrimeTrackedCodeCheckpoint {
            scheduleTrackedCodeCheckpointStartIfNeeded(
                for: targetSessionID
            )
        }
    }

    private static func archivedToolCall(from call: AssistantToolCallState) -> AssistantToolCallState {
        var archived = call
        let normalizedStatus = archived.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["inprogress", "running", "working", "active", "started", "pending"].contains(normalizedStatus) {
            archived.status = "completed"
        }
        return archived
    }

    private func finalizeToolCallsForTurn(
        state: inout AssistantSessionExecutionState,
        status: AssistantTurnCompletionStatus
    ) {
        guard !state.toolCalls.isEmpty else { return }

        let finalizedCalls = state.toolCalls.map { call -> AssistantToolCallState in
            var finalized = call
            let normalizedStatus = finalized.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard ["inprogress", "running", "working", "active", "started", "pending"].contains(normalizedStatus) else {
                return finalized
            }

            switch status {
            case .completed:
                finalized.status = "completed"
            case .interrupted:
                finalized.status = "interrupted"
            case .failed:
                finalized.status = "failed"
            }

            return finalized
        }

        let finalizedIDs = Set(finalizedCalls.map(\.id))
        state.recentToolCalls.removeAll { finalizedIDs.contains($0.id) }
        state.recentToolCalls.insert(contentsOf: finalizedCalls, at: 0)
        if state.recentToolCalls.count > 24 {
            state.recentToolCalls = Array(state.recentToolCalls.prefix(24))
        }
        state.toolCalls = []
    }

    private func updateVisibleSessionPreview(with entry: AssistantTranscriptEntry, sessionID: String? = nil) {
        guard let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? selectedSessionID,
              let sessionIndex = sessions.firstIndex(where: { sessionsMatch($0.id, sessionID) }),
              let text = entry.text.assistantNonEmpty else {
            return
        }

        sessions[sessionIndex].updatedAt = entry.createdAt
        switch entry.role {
        case .user:
            sessions[sessionIndex].latestUserMessage = text
            if Self.shouldApplyPromptDerivedSessionTitle(
                existingTitle: sessions[sessionIndex].title,
                fallbackTitle: Self.sessionTitle(from: text),
                cwd: sessions[sessionIndex].cwd ?? ""
            ) {
                sessions[sessionIndex].title = Self.sessionTitle(from: text)
            }
        case .assistant:
            sessions[sessionIndex].latestAssistantMessage = text
        default:
            break
        }
        persistManagedSessionsSnapshot()
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
        if let selectedProjectFilter,
           !isProjectFilterVisible(selectedProjectFilter) {
            self.selectedProjectFilter = nil
        }
    }

    private func reloadTemporarySessionsFromStore() {
        temporarySessionIDs = temporarySessionStore.temporarySessionIDs()
    }

    private func filterRestorableSessions(_ sessions: [AssistantSessionSummary]) -> [AssistantSessionSummary] {
        sessions.filter { session in
            guard let normalizedSessionID = normalizedSessionID(session.id) else {
                return false
            }
            guard !deletedSessionIDs.contains(normalizedSessionID) else {
                return false
            }
            return session.conversationPersistence != .transient
        }
    }

    private func markSessionPendingDeletion(_ sessionID: String?) {
        guard let normalizedSessionID = normalizedSessionID(sessionID) else { return }
        deletedSessionIDs.insert(normalizedSessionID)
        cancelPendingConversationSnapshotSave(sessionID: normalizedSessionID)
        dirtyConversationSnapshotSessionIDs.remove(normalizedSessionID)
    }

    private func setTemporaryFlag(
        _ isTemporary: Bool,
        for sessionID: String?,
        reportErrors: Bool
    ) {
        do {
            if isTemporary, let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
                try temporarySessionStore.markTemporary(sessionID)
            } else {
                try temporarySessionStore.removeTemporaryFlag(sessionID)
            }
            reloadTemporarySessionsFromStore()
            sessions = applyTemporaryMetadata(to: sessions)
        } catch {
            if reportErrors {
                lastStatusMessage = error.localizedDescription
            } else {
                CrashReporter.logError("Temporary session flag update failed: \(error.localizedDescription)")
            }
        }
    }

    private func isTemporarySession(_ sessionID: String?) -> Bool {
        guard let normalizedSessionID = normalizedSessionID(sessionID) else {
            return false
        }
        return temporarySessionIDs.contains(normalizedSessionID)
    }

    private func resolvedProjectFilter(for itemID: String?) -> AssistantProjectFilter? {
        guard let normalizedItemID = itemID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
              let project = visibleProjects.first(where: {
                  $0.id.trimmingCharacters(in: .whitespacesAndNewlines)
                      .caseInsensitiveCompare(normalizedItemID) == .orderedSame
              }) else {
            return nil
        }

        return project.isFolder ? .folder(project.id) : .project(project.id)
    }

    private func isProjectFilterVisible(_ filter: AssistantProjectFilter) -> Bool {
        switch filter {
        case .folder(let folderID):
            return visibleFolders.contains(where: {
                $0.id.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare(folderID) == .orderedSame
            })
        case .project(let projectID):
            return visibleLeafProjects.contains(where: {
                $0.id.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare(projectID) == .orderedSame
            })
        }
    }

    private func ensureSelectedSessionRemainsVisible(
        afterRemovingProjectID removedProjectID: String?
    ) async {
        let selectedSessionStillVisible = selectedSessionID.flatMap { currentSelectedSessionID in
            visibleSidebarSessions.first(where: { sessionsMatch($0.id, currentSelectedSessionID) })
        } != nil
        guard !selectedSessionStillVisible else { return }

        if let firstVisibleSession = visibleSidebarSessions.first {
            await openSession(firstVisibleSession)
        } else if isTemporarySession(selectedSessionID) {
            await deleteSession(selectedSessionID, showStatusMessage: false)
        } else {
            if let staleSessionID = selectedSessionID ?? removedProjectID {
                clearInMemorySessionState(for: staleSessionID)
            }
            refreshMemoryState(for: nil)
        }
    }

    func selectProjectFilter(
        _ projectID: String?,
        autoSelectVisibleSessionIfNeeded: Bool = true,
        toggleOffIfSame: Bool = true
    ) async {
        let nextFilter = resolvedProjectFilter(for: projectID)
        if let nextFilter,
           selectedProjectFilter == nextFilter {
            if toggleOffIfSame {
                selectedProjectFilter = nil
            }
            return
        }

        if let nextFilter,
           !isProjectFilterVisible(nextFilter) {
            selectedProjectFilter = nil
            return
        }

        let previousSelectedSessionID = selectedSessionID

        selectedProjectFilter = nextFilter

        guard nextFilter != nil else { return }
        guard autoSelectVisibleSessionIfNeeded else { return }
        let selectedSessionStillVisible = selectedSessionID.flatMap { currentSelectedSessionID in
            visibleSidebarSessions.first(where: { sessionsMatch($0.id, currentSelectedSessionID) })
        } != nil
        if !selectedSessionStillVisible,
           let firstVisibleSession = visibleSidebarSessions.first {
            await openSession(firstVisibleSession)
        } else if !selectedSessionStillVisible,
                  isTemporarySession(previousSelectedSessionID) {
            await deleteSession(previousSelectedSessionID, showStatusMessage: false)
        }
    }

    func createProject(
        name: String,
        linkedFolderPath: String? = nil,
        parentID: String? = nil
    ) {
        do {
            let project = try projectStore.createProject(
                name: name,
                linkedFolderPath: linkedFolderPath,
                parentID: parentID
            )
            reloadProjectsFromStore()
            sessions = applyStoredSessionMetadata(to: sessions)
            refreshMemoryInspectorIfNeeded(affectedProjectIDs: [project.id])
        } catch {
            lastStatusMessage = error.localizedDescription
        }
    }

    func createFolder(name: String) {
        do {
            _ = try projectStore.createFolder(name: name)
            reloadProjectsFromStore()
            sessions = applyStoredSessionMetadata(to: sessions)
        } catch {
            lastStatusMessage = error.localizedDescription
        }
    }

    func renameProject(_ projectID: String, to newName: String) {
        do {
            let updatedProject = try projectStore.renameProject(id: projectID, to: newName)
            reloadProjectsFromStore()
            sessions = applyStoredSessionMetadata(to: sessions)
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
            sessions = applyStoredSessionMetadata(to: sessions)
            if case .project(let selectedProjectID)? = selectedProjectFilter,
               selectedProjectID.caseInsensitiveCompare(projectID) == .orderedSame,
               updatedProject.id.caseInsensitiveCompare(projectID) != .orderedSame {
                selectedProjectFilter = .project(updatedProject.id)
            }

            if previousFolderPath != updatedProject.linkedFolderPath,
               let representativeThreadID = representativeThreadID(forProjectID: updatedProject.id) {
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

    func moveProject(_ projectID: String, toFolderID folderID: String?) {
        do {
            let movedProject = try projectStore.moveProject(id: projectID, toFolderID: folderID)
            reloadProjectsFromStore()
            sessions = applyStoredSessionMetadata(to: sessions)
            refreshMemoryState(for: selectedSessionID)
            refreshMemoryInspectorIfNeeded(affectedProjectIDs: [movedProject.id])
        } catch {
            lastStatusMessage = error.localizedDescription
        }
    }

    func hideProject(_ projectID: String) async {
        do {
            let normalizedProjectID = projectID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedProjectID.isEmpty else { return }
            guard let project = projectStore.project(forProjectID: normalizedProjectID) else {
                throw AssistantProjectStoreError.projectNotFound
            }

            let hiddenProject = try projectStore.hideProject(id: normalizedProjectID)
            reloadProjectsFromStore()
            sessions = applyStoredSessionMetadata(to: sessions)
            refreshMemoryInspectorIfNeeded(affectedProjectIDs: [normalizedProjectID], closeIfMissing: true)
            if let selectedProjectFilter,
               !isProjectFilterVisible(selectedProjectFilter) {
                self.selectedProjectFilter = nil
            }
            await ensureSelectedSessionRemainsVisible(afterRemovingProjectID: project.isProject ? project.id : nil)

            let itemLabel = hiddenProject.isFolder ? "group" : "project"
            lastStatusMessage = "Hidden \(itemLabel) “\(hiddenProject.name)”."
        } catch {
            lastStatusMessage = error.localizedDescription
        }
    }

    func unhideProject(_ projectID: String) async {
        do {
            let normalizedProjectID = projectID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedProjectID.isEmpty else { return }
            let unhiddenProject = try projectStore.unhideProject(id: normalizedProjectID)
            reloadProjectsFromStore()
            sessions = applyStoredSessionMetadata(to: sessions)
            refreshMemoryInspectorIfNeeded(affectedProjectIDs: [normalizedProjectID], closeIfMissing: true)
            let itemLabel = unhiddenProject.isFolder ? "group" : "project"
            lastStatusMessage = "Unhidden \(itemLabel) “\(unhiddenProject.name)”."
        } catch {
            lastStatusMessage = error.localizedDescription
        }
    }

    func deleteProject(_ projectID: String) async {
        do {
            guard let project = projectStore.project(forProjectID: projectID) else { return }
            let deletion = try projectStore.deleteProjectResult(id: projectID)
            if project.isProject {
                try projectMemoryService.invalidateAllProjectLessons(
                    project: project,
                    fallbackCWD: project.linkedFolderPath,
                    reason: "The project was deleted from Open Assist."
                )
            }

            reloadProjectsFromStore()
            sessions = applyStoredSessionMetadata(to: sessions)

            if let selectedProjectFilter,
               !isProjectFilterVisible(selectedProjectFilter) {
                self.selectedProjectFilter = nil
            }

            for threadID in deletion.removedThreadIDs where sessionsMatch(threadID, selectedSessionID) {
                refreshMemoryState(for: threadID)
            }
            refreshMemoryInspectorIfNeeded(
                affectedThreadIDs: deletion.removedThreadIDs,
                affectedProjectIDs: [projectID],
                closeIfMissing: true
            )
            await ensureSelectedSessionRemainsVisible(afterRemovingProjectID: project.isProject ? project.id : nil)
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
        sessions = applyStoredSessionMetadata(to: sessions)
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

    private func applyTemporaryMetadata(to sessions: [AssistantSessionSummary]) -> [AssistantSessionSummary] {
        let effectiveTemporarySessionIDs = assistantEffectiveTemporarySessionIDs(
            storedTemporaryIDs: temporarySessionIDs,
            sessions: sessions
        )
        return sessions.map { session in
            var updated = session
            updated.isTemporary = effectiveTemporarySessionIDs.contains(
                normalizedAssistantSessionKey(session.id) ?? ""
            )
            return updated
        }
    }

    private func applyStoredSessionMetadata(to sessions: [AssistantSessionSummary]) -> [AssistantSessionSummary] {
        applyTemporaryMetadata(to: applyProjectMetadata(to: sessions))
    }

    private func resolvedProjectLinkedFolderPath(_ path: String?) -> String? {
        guard let normalizedPath = AssistantProject.normalizedLinkedFolderPath(path),
              fileManagerDirectoryExists(atPath: normalizedPath) else {
            return nil
        }
        return normalizedPath
    }

    private func selectedProjectLinkedFolderPathIfUsable() -> String? {
        guard let linkedFolderPath = selectedProject?.linkedFolderPath else {
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
                if let projectID = session.projectID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
                   projectStore.project(forProjectID: projectID)?.isHidden == true {
                    dismissMemoryInspector()
                    return
                }
                memoryInspectorSnapshot = try memoryInspectorService.snapshot(for: session)
            case .project(let projectID):
                guard let project = visibleProjects.first(where: {
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

        self.sessions = applyStoredSessionMetadata(to: self.sessions)
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
                transcript: history.1
            )
            if result.didChange {
                let affectedProjectID = session.projectID
                reloadProjectsFromStore()
                sessions = applyStoredSessionMetadata(to: sessions)
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
              let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
              !isProviderIndependentThreadV2(sessionID: sessionID) else {
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

    var canStepHistoryBranchBackward: Bool {
        guard let branch = historyBranchState else {
            return false
        }

        let normalizedSessionID = branch.sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionID.isEmpty else { return false }

        if let cachedTurns = editableTurnsBySessionID[normalizedSessionID] {
            return !cachedTurns.isEmpty
        }

        if let turns = try? threadRewriteService.editableTurns(sessionID: normalizedSessionID) {
            setEditableTurns(turns, for: normalizedSessionID)
            return !turns.isEmpty
        }

        return false
    }

    var historyRestoreItems: [AssistantHistoryRestoreItem] {
        guard let branch = historyBranchState,
              sessionsMatch(branch.sessionID, selectedSessionID) else {
            return []
        }

        return branch.futureStates.map {
            AssistantHistoryRestoreItem(
                id: $0.id,
                anchorID: $0.restoreAnchorID,
                title: $0.title
            )
        }
    }

    private func latestCheckpointBoundaryDate(
        for sessionID: String,
        trackingState: AssistantCodeTrackingState?
    ) -> Date? {
        guard let trackingState,
              trackingState.availability == .available,
              let currentCheckpoint = trackingState.currentCheckpoint else {
            return nil
        }

        let sessionTimeline = timelineItemsBySessionID[sessionID] ?? timelineItems
        if let associatedTurnID = currentCheckpoint.associatedTurnID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
           let assistantMessageDate = sessionTimeline.last(where: {
               ($0.kind == .assistantFinal || $0.kind == .assistantProgress)
                   && $0.turnID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty == associatedTurnID
           })?.createdAt {
            return assistantMessageDate
        }

        return currentCheckpoint.createdAt
    }

    private func hasPendingTrackedCodeRedo(for sessionID: String) -> Bool {
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionID.isEmpty else { return false }

        if let selectedCodeTrackingState,
           sessionsMatch(selectedCodeTrackingState.sessionID, normalizedSessionID) {
            return selectedCodeTrackingState.canRedo
        }

        if let state = codeTrackingStateBySessionID[normalizedSessionID] {
            return state.canRedo
        }

        return conversationCheckpointStore.loadTrackingState(for: normalizedSessionID)?.canRedo ?? false
    }

    private func checkpointPositionBeforeUserAnchor(
        _ anchorID: String,
        in state: AssistantCodeTrackingState
    ) -> Int {
        let normalizedAnchorID = anchorID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedAnchorID.isEmpty else {
            return state.currentCheckpointPosition
        }

        guard let checkpointIndex = state.checkpoints.firstIndex(where: {
            $0.associatedUserAnchorID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty == normalizedAnchorID
        }) else {
            return state.currentCheckpointPosition
        }

        return checkpointIndex - 1
    }

    private func persistHistoryBranchState(
        _ branch: AssistantHistoryBranchState,
        currentTrackingState: AssistantCodeTrackingState? = nil
    ) {
        var state = currentTrackingState ?? effectiveCodeTrackingState(for: branch.sessionID)
        state.currentCheckpointPosition = branch.currentCheckpointPosition
        state.historyBranchState = branch
        publishCodeTrackingState(state)
    }

    private func clearPersistedHistoryBranchState(
        for sessionID: String,
        currentTrackingState: AssistantCodeTrackingState? = nil
    ) {
        var state = currentTrackingState ?? effectiveCodeTrackingState(for: sessionID)
        state.historyBranchState = nil
        publishCodeTrackingState(state)
    }

    private func synchronizePersistedHistoryBranchState(
        for sessionID: String,
        state: AssistantCodeTrackingState
    ) {
        guard sessionsMatch(selectedSessionID, sessionID) else {
            if sessionsMatch(historyBranchState?.sessionID, sessionID) {
                historyBranchState = nil
            }
            return
        }

        if let branchState = state.historyBranchState {
            let shouldRestoreComposer = historyBranchState == nil
                || !sessionsMatch(historyBranchState?.sessionID, sessionID)
                || historyBranchState != branchState
            historyBranchState = branchState
            if shouldRestoreComposer {
                promptDraft = branchState.currentPrompt
                attachments = branchState.currentAttachments
            }
        } else if sessionsMatch(historyBranchState?.sessionID, sessionID) {
            historyBranchState = nil
        }
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
        let trackingState = codeTrackingStateBySessionID[sessionID] ?? selectedCodeTrackingState
        let hasPendingCheckpointRedo = hasPendingTrackedCodeRedo(for: sessionID)
        let branchActive = sessionsMatch(historyBranchState?.sessionID, sessionID)
        let canUndoMutate = !isRestoringHistoryBranch
            && (!hasPendingCheckpointRedo || branchActive)
        let canEditMutate = !isRestoringHistoryBranch
            && !branchActive
            && !hasPendingCheckpointRedo
        let shouldConsiderCheckpointUndo =
            settings.assistantTrackCodeChangesInGitRepos
            && interactionMode.normalizedForActiveUse == .agentic
            && trackingState?.availability == .available
            && !(trackingState?.checkpoints.isEmpty ?? true)
        let latestCheckpointDate = shouldConsiderCheckpointUndo
            ? latestCheckpointBoundaryDate(for: sessionID, trackingState: trackingState)
            : nil

        var metadata: [String: AssistantHistoryActionAvailability] = [:]
        let latestMappedIndex = itemTail.indices.last
        for (index, pair) in zip(itemTail.indices, zip(itemTail, turnTail)) {
            let (item, turn) = pair
            let latestRelevantDate = max(item.createdAt, turn.createdAt)
            let shouldPreferCheckpointUndo = latestCheckpointDate.map {
                latestRelevantDate <= $0
            } ?? false
            let isLatestMappedMessage = index == latestMappedIndex
            metadata[item.id] = AssistantHistoryActionAvailability(
                anchorID: turn.anchorID,
                canUndo: canUndoMutate
                    && !shouldPreferCheckpointUndo
                    && isLatestMappedMessage,
                canEdit: canEditMutate
                    && !shouldPreferCheckpointUndo
                    && turn.supportsEdit
                    && isLatestMappedMessage
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

        let memoryDocumentMarkdown = captureSnapshot
            ? (try? threadMemoryService.loadTrackedDocument(for: normalizedSessionID).document.markdown)
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
            memoryDocumentMarkdown: memoryDocumentMarkdown,
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

        if let memoryDocumentMarkdown = snapshot.memoryDocumentMarkdown {
            let memoryDocument = AssistantThreadMemoryDocument.parse(markdown: memoryDocumentMarkdown)
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

    private func resetIdleCodeCheckpointRecoveryAttempt(for sessionID: String) {
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionID.isEmpty else { return }
        idleCodeCheckpointRecoveryAttemptedSessionIDs.remove(normalizedSessionID)
    }

    private func markIdleCodeCheckpointRecoveryAttemptIfNeeded(for sessionID: String) -> Bool {
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionID.isEmpty else { return false }
        return idleCodeCheckpointRecoveryAttemptedSessionIDs.insert(normalizedSessionID).inserted
    }

    private func beginTrackedCodeCheckpointIfNeeded(for sessionID: String) async {
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionID.isEmpty else { return }
        resetIdleCodeCheckpointRecoveryAttempt(for: normalizedSessionID)
        guard settings.assistantTrackCodeChangesInGitRepos,
              interactionMode.normalizedForActiveUse == .agentic else {
            await refreshCodeTrackingState(for: normalizedSessionID)
            return
        }
        guard pendingCodeCheckpointBaselinesBySessionID[normalizedSessionID] == nil else {
            return
        }

        pendingCodeCheckpointRecoveryRetryTasksBySessionID.removeValue(forKey: normalizedSessionID)?.cancel()

        let existingState = codeTrackingStateBySessionID[normalizedSessionID]
            ?? conversationCheckpointStore.loadTrackingState(for: normalizedSessionID)
        guard let repository = await resolvedTrackedCodeRepository(
            for: normalizedSessionID,
            fallbackState: existingState
        ) else {
            await refreshCodeTrackingState(for: normalizedSessionID)
            return
        }

        let checkpointID = UUID().uuidString
        var capturedBeforeSnapshot: GitCheckpointSnapshot?
        do {
            CrashReporter.logInfo(
                "Tracked coding begin checkpoint sessionID=\(normalizedSessionID) checkpointID=\(checkpointID)"
            )
            let beforeSnapshot = try await gitCheckpointService.captureSnapshot(
                repository: repository,
                sessionID: normalizedSessionID,
                checkpointID: checkpointID,
                phase: .before
            )
            capturedBeforeSnapshot = beforeSnapshot
            CrashReporter.logInfo(
                "Tracked coding captured before snapshot sessionID=\(normalizedSessionID) checkpointID=\(checkpointID)"
            )
            if Task.isCancelled {
                CrashReporter.logWarning(
                    "Tracked coding begin cancelled after before snapshot sessionID=\(normalizedSessionID) checkpointID=\(checkpointID)"
                )
                return
            }

            pendingCodeCheckpointBaselinesBySessionID[normalizedSessionID] = AssistantPendingCodeCheckpointBaseline(
                sessionID: normalizedSessionID,
                checkpointID: checkpointID,
                repository: repository,
                beforeSnapshot: beforeSnapshot,
                startedAt: Date()
            )
            CrashReporter.logInfo(
                "Tracked coding stored in-memory baseline sessionID=\(normalizedSessionID) checkpointID=\(checkpointID)"
            )

            var state = effectiveCodeTrackingState(for: normalizedSessionID)
            state.availability = .available
            state.repoRootPath = repository.rootPath
            state.repoLabel = repository.label
            CrashReporter.logInfo(
                "Tracked coding publishing availability state sessionID=\(normalizedSessionID) checkpointID=\(checkpointID)"
            )
            publishCodeTrackingState(state)
            CrashReporter.logInfo(
                "Tracked coding begin baseline ready sessionID=\(normalizedSessionID) checkpointID=\(checkpointID)"
            )

            scheduleConversationCheckpointCapture(
                sessionID: normalizedSessionID,
                checkpointID: checkpointID,
                phase: .before
            )
            try? await waitForPendingConversationCheckpointCapture(
                sessionID: normalizedSessionID,
                checkpointID: checkpointID,
                phase: .before
            )
        } catch {
            CrashReporter.logError(
                "Tracked coding begin failed sessionID=\(normalizedSessionID) checkpointID=\(checkpointID) error=\(error.localizedDescription)"
            )
            pendingCodeCheckpointBaselinesBySessionID.removeValue(forKey: normalizedSessionID)
            await deleteTrackedCodeCheckpointArtifacts(
                sessionID: normalizedSessionID,
                checkpointIDs: [checkpointID],
                repositoryRootPath: repository.rootPath,
                checkpoints: [],
                additionalRefs: capturedBeforeSnapshot.map {
                    [
                        $0.worktreeRef,
                        $0.indexRef
                    ]
                } ?? []
            )
            lastStatusMessage = "Tracked coding could not save the starting checkpoint for this turn."
            await refreshCodeTrackingState(for: normalizedSessionID)
        }
    }

    private func scheduleTrackedCodeCheckpointStartIfNeeded(for sessionID: String?) {
        guard let normalizedSessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return
        }
        guard settings.assistantTrackCodeChangesInGitRepos,
              interactionMode.normalizedForActiveUse == .agentic else {
            return
        }
        guard pendingCodeCheckpointBaselinesBySessionID[normalizedSessionID] == nil,
              pendingCodeCheckpointStartTasksBySessionID[normalizedSessionID] == nil else {
            return
        }

        pendingCodeCheckpointStartTasksBySessionID[normalizedSessionID] = Task { @MainActor [weak self] in
            defer {
                self?.pendingCodeCheckpointStartTasksBySessionID.removeValue(forKey: normalizedSessionID)
            }
            await self?.beginTrackedCodeCheckpointIfNeeded(for: normalizedSessionID)
        }
    }

    private func waitForTrackedCodeCheckpointStartIfNeeded(for sessionID: String?) async {
        guard let normalizedSessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return
        }
        let deadline = Date().addingTimeInterval(1.0)
        while pendingCodeCheckpointStartTasksBySessionID[normalizedSessionID] != nil,
              pendingCodeCheckpointBaselinesBySessionID[normalizedSessionID] == nil,
              Date() < deadline {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    private func prepareTrackedCodeCheckpointIfNeeded(
        for request: AssistantPermissionRequest,
        optionID: String
    ) async {
        guard optionID == "accept" || optionID == "acceptForSession" else { return }
        guard let toolKind = request.toolKind else { return }

        switch toolKind {
        case "commandExecution", "fileChange":
            await beginTrackedCodeCheckpointIfNeeded(for: request.sessionID)
        default:
            return
        }
    }

    private func scheduleTrackedCodeCheckpointFinalizeRetryAfterPendingStart(
        for sessionID: String,
        turnID: String?,
        status: AssistantTurnCompletionStatus,
        startTask: Task<Void, Never>
    ) {
        guard pendingCodeCheckpointRecoveryRetryTasksBySessionID[sessionID] == nil else {
            return
        }

        pendingCodeCheckpointRecoveryRetryTasksBySessionID[sessionID] = Task { @MainActor [weak self] in
            await startTask.value
            guard let self else { return }
            self.pendingCodeCheckpointRecoveryRetryTasksBySessionID.removeValue(forKey: sessionID)
            await self.finalizeTrackedCodeCheckpoint(
                for: sessionID,
                turnID: turnID,
                status: status
            )
        }
    }

    private func finalizeTrackedCodeCheckpoint(
        for sessionID: String?,
        turnID: String? = nil,
        status: AssistantTurnCompletionStatus
    ) async {
        guard let normalizedSessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return
        }
        resetIdleCodeCheckpointRecoveryAttempt(for: normalizedSessionID)

        await waitForTrackedCodeCheckpointStartIfNeeded(for: normalizedSessionID)

        if pendingCodeCheckpointBaselinesBySessionID[normalizedSessionID] == nil,
           let task = pendingCodeCheckpointStartTasksBySessionID[normalizedSessionID] {
            scheduleTrackedCodeCheckpointFinalizeRetryAfterPendingStart(
                for: normalizedSessionID,
                turnID: turnID,
                status: status,
                startTask: task
            )
            CrashReporter.logInfo(
                "Tracked coding start still running sessionID=\(normalizedSessionID); scheduling finalize retry after start completes"
            )
            return
        }

        guard let baseline = pendingCodeCheckpointBaselinesBySessionID.removeValue(forKey: normalizedSessionID) else {
            let existingState = codeTrackingStateBySessionID[normalizedSessionID]
                ?? conversationCheckpointStore.loadTrackingState(for: normalizedSessionID)
            if let repository = await resolvedTrackedCodeRepository(
                for: normalizedSessionID,
                fallbackState: existingState
            ),
               await recoverIncompleteTrackedCodeCheckpointsIfNeeded(
                    for: normalizedSessionID,
                    repository: repository,
                    turnID: turnID,
                    status: status
               ) {
                CrashReporter.logInfo(
                    "Tracked coding recovered checkpoint without in-memory baseline sessionID=\(normalizedSessionID)"
                )
                return
            }
            CrashReporter.logWarning(
                "Tracked coding finalize found no pending baseline sessionID=\(normalizedSessionID)"
            )
            await refreshCodeTrackingState(for: normalizedSessionID)
            return
        }

        var capturedAfterSnapshot: GitCheckpointSnapshot?
        do {
            CrashReporter.logInfo(
                "Tracked coding finalize checkpoint sessionID=\(normalizedSessionID) checkpointID=\(baseline.checkpointID)"
            )
            let afterSnapshot = try await gitCheckpointService.captureSnapshot(
                repository: baseline.repository,
                sessionID: normalizedSessionID,
                checkpointID: baseline.checkpointID,
                phase: .after
            )
            capturedAfterSnapshot = afterSnapshot
            CrashReporter.logInfo(
                "Tracked coding captured after snapshot sessionID=\(normalizedSessionID) checkpointID=\(baseline.checkpointID)"
            )
            let touchedPaths = trackedCodeTouchedPaths(
                for: normalizedSessionID,
                turnID: turnID,
                startedAt: baseline.startedAt,
                repositoryRootPath: baseline.repository.rootPath
            )
            let captureResolution = try await gitCheckpointService.buildCaptureResultWithFullDiffFallback(
                repository: baseline.repository,
                before: baseline.beforeSnapshot,
                after: afterSnapshot,
                includedPaths: touchedPaths.isEmpty ? nil : touchedPaths
            )
            let capture = captureResolution.capture
            if captureResolution.usedUnfilteredFallback {
                CrashReporter.logWarning(
                    "Tracked coding finalize fell back to full checkpoint diff sessionID=\(normalizedSessionID) checkpointID=\(baseline.checkpointID) touchedPathCount=\(touchedPaths.count) files=\(capture.changedFiles.count)"
                )
            }

            guard !capture.changedFiles.isEmpty else {
                CrashReporter.logInfo(
                    "Tracked coding finalize found no tracked code diff sessionID=\(normalizedSessionID) checkpointID=\(baseline.checkpointID) touchedPathCount=\(touchedPaths.count)"
                )
                await deleteTrackedCodeCheckpointArtifacts(
                    sessionID: normalizedSessionID,
                    checkpointIDs: [baseline.checkpointID],
                    repositoryRootPath: baseline.repository.rootPath,
                    checkpoints: [],
                    additionalRefs: [
                        baseline.beforeSnapshot.worktreeRef,
                        baseline.beforeSnapshot.indexRef,
                        afterSnapshot.worktreeRef,
                        afterSnapshot.indexRef
                    ]
                )
                await refreshCodeTrackingState(for: normalizedSessionID)
                return
            }

            var state = effectiveCodeTrackingState(for: normalizedSessionID)
            state.availability = .available
            state.repoRootPath = baseline.repository.rootPath
            state.repoLabel = baseline.repository.label
            state = await truncatingFutureTrackedCodeCheckpointsIfNeeded(
                state,
                repositoryRootPath: baseline.repository.rootPath
            )

            // Find the last assistant message ID for this session's current turn
            let sessionTimeline = timelineItemsBySessionID[normalizedSessionID] ?? timelineItems
            let lastAssistantMessage = sessionTimeline.last(where: {
                $0.kind == .assistantFinal || $0.kind == .assistantProgress
            })
            let lastUserMessage = sessionTimeline.last(where: { $0.kind == .userMessage })
            let lastAssistantMessageID = lastAssistantMessage?.id
            let lastAssistantTurnID = lastAssistantMessage?.turnID?.nonEmpty
            let lastUserMessageID = lastUserMessage?.id
            let lastUserAnchorID = (try? threadRewriteService.editableTurns(sessionID: normalizedSessionID))?.last?.anchorID

            let checkpoint = AssistantCodeCheckpointSummary(
                id: baseline.checkpointID,
                checkpointNumber: state.checkpoints.count + 1,
                createdAt: Date(),
                turnStatus: trackedCodeTurnStatus(from: status),
                summary: capture.summary,
                patch: capture.patch,
                changedFiles: capture.changedFiles,
                ignoredTouchedPaths: capture.ignoredTouchedPaths,
                beforeSnapshot: baseline.beforeSnapshot,
                afterSnapshot: afterSnapshot,
                associatedMessageID: lastAssistantMessageID,
                associatedTurnID: lastAssistantTurnID,
                associatedUserMessageID: lastUserMessageID,
                associatedUserAnchorID: lastUserAnchorID
            )
            state.checkpoints.append(checkpoint)
            state.currentCheckpointPosition = state.checkpoints.count - 1
            publishCodeTrackingState(state)
            CrashReporter.logInfo(
                "Tracked coding published checkpoint sessionID=\(normalizedSessionID) checkpointID=\(baseline.checkpointID) files=\(capture.changedFiles.count)"
            )

            scheduleConversationCheckpointCapture(
                sessionID: normalizedSessionID,
                checkpointID: baseline.checkpointID,
                phase: .after
            )
            try? await waitForPendingConversationCheckpointCapture(
                sessionID: normalizedSessionID,
                checkpointID: baseline.checkpointID,
                phase: .after
            )

            if checkpoint.hasIgnoredCoverageWarning {
                lastStatusMessage = "Tracked coding saved this checkpoint, but ignored files were also changed and cannot be undone automatically."
            }
        } catch {
            CrashReporter.logError(
                "Tracked coding finalize failed sessionID=\(normalizedSessionID) checkpointID=\(baseline.checkpointID) error=\(error.localizedDescription)"
            )
            await deleteTrackedCodeCheckpointArtifacts(
                sessionID: normalizedSessionID,
                checkpointIDs: [baseline.checkpointID],
                repositoryRootPath: baseline.repository.rootPath,
                checkpoints: [],
                additionalRefs: [
                    baseline.beforeSnapshot.worktreeRef,
                    baseline.beforeSnapshot.indexRef
                ] + (capturedAfterSnapshot.map {
                    [
                        $0.worktreeRef,
                        $0.indexRef
                    ]
                } ?? [])
            )
            lastStatusMessage = error.localizedDescription
            await refreshCodeTrackingState(for: normalizedSessionID)
        }
    }

    @discardableResult
    private func recoverIncompleteTrackedCodeCheckpointsIfNeeded(
        for sessionID: String,
        repository: GitCheckpointRepositoryContext,
        turnID: String?,
        status: AssistantTurnCompletionStatus?
    ) async -> Bool {
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionID.isEmpty else { return false }
        guard pendingCodeCheckpointBaselinesBySessionID[normalizedSessionID] == nil else {
            return false
        }

        let storedRefs: [GitStoredCheckpointRefState]
        do {
            storedRefs = try await gitCheckpointService.storedCheckpointRefs(
                repository: repository,
                sessionID: normalizedSessionID
            )
            CrashReporter.logInfo(
                "Tracked coding scanned stored refs sessionID=\(normalizedSessionID) refCount=\(storedRefs.count)"
            )
        } catch {
            CrashReporter.logError(
                "Tracked coding ref scan failed sessionID=\(normalizedSessionID) error=\(error.localizedDescription)"
            )
            return false
        }

        var state = effectiveCodeTrackingState(for: normalizedSessionID)
        state.availability = .available
        state.repoRootPath = repository.rootPath
        state.repoLabel = repository.label
        let hadStoredRefs = !storedRefs.isEmpty
        let hadExistingCheckpoints = !state.checkpoints.isEmpty

        let existingCheckpointIDs = Set(state.checkpoints.map(\.id))
        let recoverableRefs = storedRefs.filter {
            $0.hasBeforeSnapshot && !existingCheckpointIDs.contains($0.checkpointID)
        }
        guard !recoverableRefs.isEmpty else {
            if hadStoredRefs && !hadExistingCheckpoints {
                CrashReporter.logInfo(
                    "Tracked coding recovery saw incomplete stored refs sessionID=\(normalizedSessionID); will retry on next refresh"
                )
                resetIdleCodeCheckpointRecoveryAttempt(for: normalizedSessionID)
            }
            return false
        }

        var didRecover = false
        var didTruncateFutureCheckpoints = false
        let shouldPreserveCurrentCheckpointPosition = status == nil && hadExistingCheckpoints
        let sessionTimeline = timelineItemsBySessionID[normalizedSessionID] ?? timelineItems
        let lastAssistantMessage = sessionTimeline.last(where: {
            $0.kind == .assistantFinal || $0.kind == .assistantProgress
        })
        let lastUserMessage = sessionTimeline.last(where: { $0.kind == .userMessage })
        let lastAssistantMessageID = lastAssistantMessage?.id
        let lastAssistantTurnID = lastAssistantMessage?.turnID?.nonEmpty
        let lastUserMessageID = lastUserMessage?.id
        let lastUserAnchorID = (try? threadRewriteService.editableTurns(sessionID: normalizedSessionID))?.last?.anchorID

        for refState in recoverableRefs {
            do {
                CrashReporter.logInfo(
                    "Tracked coding evaluating stored checkpoint sessionID=\(normalizedSessionID) checkpointID=\(refState.checkpointID) hasAfter=\(refState.hasAfterSnapshot)"
                )
                guard let beforeSnapshot = try await gitCheckpointService.loadSnapshot(
                    repository: repository,
                    sessionID: normalizedSessionID,
                    checkpointID: refState.checkpointID,
                    phase: .before
                ) else {
                    CrashReporter.logWarning(
                        "Tracked coding stored before snapshot missing sessionID=\(normalizedSessionID) checkpointID=\(refState.checkpointID)"
                    )
                    continue
                }

                let afterSnapshot: GitCheckpointSnapshot
                if refState.hasAfterSnapshot,
                   let loadedAfterSnapshot = try await gitCheckpointService.loadSnapshot(
                        repository: repository,
                        sessionID: normalizedSessionID,
                        checkpointID: refState.checkpointID,
                        phase: .after
                   ) {
                    afterSnapshot = loadedAfterSnapshot
                } else {
                    afterSnapshot = try await gitCheckpointService.captureSnapshot(
                        repository: repository,
                        sessionID: normalizedSessionID,
                        checkpointID: refState.checkpointID,
                        phase: .after
                    )
                }
                let capture = try await gitCheckpointService.buildCaptureResult(
                    repository: repository,
                    before: beforeSnapshot,
                    after: afterSnapshot,
                    includedPaths: nil
                )

                if capture.changedFiles.isEmpty {
                    CrashReporter.logInfo(
                        "Tracked coding recovery found no tracked code diff sessionID=\(normalizedSessionID) checkpointID=\(refState.checkpointID)"
                    )
                    await deleteTrackedCodeCheckpointArtifacts(
                        sessionID: normalizedSessionID,
                        checkpointIDs: [refState.checkpointID],
                        repositoryRootPath: repository.rootPath,
                        checkpoints: [],
                        additionalRefs: [
                            beforeSnapshot.worktreeRef,
                            beforeSnapshot.indexRef,
                            afterSnapshot.worktreeRef,
                            afterSnapshot.indexRef
                        ]
                    )
                    continue
                }

                if !didTruncateFutureCheckpoints {
                    state = await truncatingFutureTrackedCodeCheckpointsIfNeeded(
                        state,
                        repositoryRootPath: repository.rootPath
                    )
                    didTruncateFutureCheckpoints = true
                }

                let checkpoint = AssistantCodeCheckpointSummary(
                    id: refState.checkpointID,
                    checkpointNumber: state.checkpoints.count + 1,
                    createdAt: Date(),
                    turnStatus: trackedCodeTurnStatus(from: status ?? .completed),
                    summary: capture.summary,
                    patch: capture.patch,
                    changedFiles: capture.changedFiles,
                    ignoredTouchedPaths: capture.ignoredTouchedPaths,
                    beforeSnapshot: beforeSnapshot,
                    afterSnapshot: afterSnapshot,
                    associatedMessageID: lastAssistantMessageID,
                    associatedTurnID: lastAssistantTurnID,
                    associatedUserMessageID: lastUserMessageID,
                    associatedUserAnchorID: lastUserAnchorID
                )
                state.checkpoints.append(checkpoint)
                if !shouldPreserveCurrentCheckpointPosition || state.currentCheckpointPosition < 0 {
                    state.currentCheckpointPosition = state.checkpoints.count - 1
                }
                didRecover = true
                CrashReporter.logInfo(
                    "Tracked coding recovered checkpoint sessionID=\(normalizedSessionID) checkpointID=\(refState.checkpointID) files=\(capture.changedFiles.count)"
                )

                scheduleConversationCheckpointCapture(
                    sessionID: normalizedSessionID,
                    checkpointID: refState.checkpointID,
                    phase: .after
                )
            } catch {
                CrashReporter.logError(
                    "Tracked coding recovery failed sessionID=\(normalizedSessionID) checkpointID=\(refState.checkpointID) error=\(error.localizedDescription)"
                )
            }
        }

        guard didRecover else {
            if hadStoredRefs && !hadExistingCheckpoints {
                CrashReporter.logInfo(
                    "Tracked coding recovery did not restore any checkpoints sessionID=\(normalizedSessionID); will retry on next refresh"
                )
                resetIdleCodeCheckpointRecoveryAttempt(for: normalizedSessionID)
            }
            return false
        }

        CrashReporter.logInfo(
            "Tracked coding publishing recovered state sessionID=\(normalizedSessionID) checkpointCount=\(state.checkpoints.count)"
        )
        publishCodeTrackingState(state)
        return true
    }

    private func discardPendingTrackedCodeCheckpoint(for sessionID: String) async {
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        await waitForTrackedCodeCheckpointStartIfNeeded(for: normalizedSessionID)
        guard let baseline = pendingCodeCheckpointBaselinesBySessionID.removeValue(forKey: normalizedSessionID) else {
            return
        }

        await deleteTrackedCodeCheckpointArtifacts(
            sessionID: normalizedSessionID,
            checkpointIDs: [baseline.checkpointID],
            repositoryRootPath: baseline.repository.rootPath,
            checkpoints: [],
            additionalRefs: [
                baseline.beforeSnapshot.worktreeRef,
                baseline.beforeSnapshot.indexRef
            ]
        )
        await refreshCodeTrackingState(for: normalizedSessionID)
    }

    func openTrackedCodeReview(checkpointID: String? = nil) {
        guard let sessionID = selectedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
              let state = codeTrackingStateBySessionID[sessionID] ?? selectedCodeTrackingState,
              let repoRootPath = state.repoRootPath,
              let repoLabel = state.repoLabel,
              !state.checkpoints.isEmpty else {
            lastStatusMessage = "There is no saved coding checkpoint to review yet."
            return
        }

        let selectedCheckpointID = checkpointID
            ?? state.currentCheckpoint?.id
            ?? state.latestCheckpoint?.id
            ?? state.checkpoints.last?.id

        guard let selectedCheckpointID else {
            lastStatusMessage = "There is no saved coding checkpoint to review yet."
            return
        }

        selectedCodeReviewPanelState = AssistantCodeReviewPanelState(
            sessionID: sessionID,
            repoRootPath: repoRootPath,
            repoLabel: repoLabel,
            checkpoints: state.checkpoints,
            currentCheckpointPosition: state.currentCheckpointPosition,
            selectedCheckpointID: selectedCheckpointID
        )
    }

    func closeTrackedCodeReview() {
        selectedCodeReviewPanelState = nil
    }

    func undoTrackedCodeCheckpoint() async {
        guard let sessionID = selectedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            lastStatusMessage = "Open the thread first, then try Undo Code."
            return
        }
        CrashReporter.logInfo("Tracked coding undo requested sessionID=\(sessionID)")
        guard let state = codeTrackingStateBySessionID[sessionID] ?? selectedCodeTrackingState else {
            lastStatusMessage = "There is no earlier tracked coding checkpoint to undo to."
            return
        }
        guard state.canUndo,
              state.checkpoints.indices.contains(state.currentCheckpointPosition) else {
            lastStatusMessage = "There is no earlier tracked coding checkpoint to undo to."
            return
        }

        let checkpoint = state.checkpoints[state.currentCheckpointPosition]
        do {
            let anchorID = try resolveHistoryRewindAnchorID(for: checkpoint, sessionID: sessionID)
            await beginHistoryBranch(
                at: anchorID,
                kind: .checkpoint,
                targetCheckpointPosition: state.currentCheckpointPosition - 1
            )
        } catch {
            lastStatusMessage = error.localizedDescription
        }
    }

    func redoTrackedCodeCheckpoint() async {
        if let branch = historyBranchState,
           sessionsMatch(branch.sessionID, selectedSessionID) {
            await restoreNearestHistoryBranchFutureState()
            return
        }

        guard selectedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty != nil else {
            lastStatusMessage = "Open the thread first, then try Redo Code."
            return
        }
        lastStatusMessage = "Redo is available only while a rewind is still open."
    }

    func restoreTrackedCodeCheckpoint(checkpointID: String) async {
        guard let sessionID = selectedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            lastStatusMessage = "Open the thread first, then try Restore."
            return
        }
        guard let branch = historyBranchState,
              sessionsMatch(branch.sessionID, sessionID) else {
            lastStatusMessage = "Restore is available only while a rewind is still open."
            return
        }
        guard let state = codeTrackingStateBySessionID[sessionID] ?? selectedCodeTrackingState,
              let checkpointIndex = state.checkpoints.firstIndex(where: { $0.id == checkpointID }) else {
            lastStatusMessage = "Open Assist could not find that saved checkpoint."
            return
        }
        guard checkpointIndex > state.currentCheckpointPosition else {
            lastStatusMessage = "That checkpoint is already visible."
            return
        }
        guard let futureState = branch.futureStates.first(where: { $0.checkpointPosition == checkpointIndex }) else {
            lastStatusMessage = "Open Assist could not find the hidden restore point for that checkpoint."
            return
        }

        await restoreHistoryBranchFutureState(id: futureState.id)
    }

    private func trackedCodeTurnStatus(
        from status: AssistantTurnCompletionStatus
    ) -> AssistantCodeCheckpointTurnStatus {
        switch status {
        case .completed:
            return .completed
        case .interrupted:
            return .interrupted
        case .failed:
            return .failed
        }
    }

    private func effectiveCodeTrackingState(for sessionID: String) -> AssistantCodeTrackingState {
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        if let state = codeTrackingStateBySessionID[normalizedSessionID] {
            return state
        }
        var loaded = conversationCheckpointStore.loadTrackingState(for: normalizedSessionID)
            ?? AssistantCodeTrackingState.empty(sessionID: normalizedSessionID)
        let sanitized = sanitizedLoadedTrackingState(loaded)
        if sanitized != loaded {
            loaded = sanitized
            persistSanitizedTrackingStateIfNeeded(loaded)
        }
        codeTrackingStateBySessionID[normalizedSessionID] = loaded
        return loaded
    }

    private func sanitizedLoadedTrackingState(
        _ state: AssistantCodeTrackingState
    ) -> AssistantCodeTrackingState {
        guard let branch = state.historyBranchState else {
            return state
        }

        guard isPersistedHistoryBranchUsable(branch) else {
            var sanitized = state
            sanitized.historyBranchState = nil
            return sanitized
        }

        return state
    }

    private func persistSanitizedTrackingStateIfNeeded(
        _ state: AssistantCodeTrackingState
    ) {
        if !state.checkpoints.isEmpty || state.repoRootPath != nil || state.historyBranchState != nil {
            try? conversationCheckpointStore.saveTrackingState(state)
        } else {
            conversationCheckpointStore.deleteTrackingState(for: state.sessionID)
        }
    }

    private func isPersistedHistoryBranchUsable(
        _ branch: AssistantHistoryBranchState
    ) -> Bool {
        let normalizedSessionID = branch.sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionID.isEmpty else { return false }

        guard branch.futureStates.allSatisfy({
            conversationCheckpointStore.hasSnapshot(
                sessionID: normalizedSessionID,
                checkpointID: $0.snapshotID,
                phase: .after
            )
        }) else {
            return false
        }

        guard let turns = try? threadRewriteService.editableTurns(sessionID: normalizedSessionID) else {
            return false
        }

        return turns.contains(where: { $0.anchorID == branch.currentAnchorID })
    }

    private func publishCodeTrackingState(_ state: AssistantCodeTrackingState) {
        if codeTrackingStateBySessionID[state.sessionID] == state,
           (!sessionsMatch(selectedSessionID, state.sessionID) || selectedCodeTrackingState == state) {
            return
        }

        CrashReporter.logInfo(
            "Tracked coding publish state sessionID=\(state.sessionID) checkpoints=\(state.checkpoints.count) currentPosition=\(state.currentCheckpointPosition) selectedMatch=\(sessionsMatch(selectedSessionID, state.sessionID))"
        )
        codeTrackingStateBySessionID[state.sessionID] = state
        if !state.checkpoints.isEmpty || state.repoRootPath != nil || state.historyBranchState != nil {
            do {
                try conversationCheckpointStore.saveTrackingState(state)
            } catch {
                CrashReporter.logError(
                    "Tracked coding state save failed sessionID=\(state.sessionID) error=\(error.localizedDescription)"
                )
            }
        } else {
            conversationCheckpointStore.deleteTrackingState(for: state.sessionID)
        }
        if !state.checkpoints.isEmpty {
            pendingCodeCheckpointRecoveryRetryTasksBySessionID[state.sessionID]?.cancel()
            pendingCodeCheckpointRecoveryRetryTasksBySessionID.removeValue(forKey: state.sessionID)
        }

        if sessionsMatch(selectedSessionID, state.sessionID) {
            selectedCodeTrackingState = state
            synchronizeTrackedCodeReviewPanel(with: state)
            synchronizePersistedHistoryBranchState(for: state.sessionID, state: state)
        }
    }

    private func synchronizeTrackedCodeReviewPanel(with state: AssistantCodeTrackingState) {
        guard let panel = selectedCodeReviewPanelState,
              panel.sessionID == state.sessionID else {
            return
        }

        guard let repoRootPath = state.repoRootPath,
              let repoLabel = state.repoLabel,
              !state.checkpoints.isEmpty else {
            selectedCodeReviewPanelState = nil
            return
        }

        let selectedCheckpointID = state.checkpoints.contains(where: { $0.id == panel.selectedCheckpointID })
            ? panel.selectedCheckpointID
            : (state.currentCheckpoint?.id ?? state.latestCheckpoint?.id ?? state.checkpoints.last?.id ?? "")
        guard !selectedCheckpointID.isEmpty else {
            selectedCodeReviewPanelState = nil
            return
        }

        selectedCodeReviewPanelState = AssistantCodeReviewPanelState(
            sessionID: state.sessionID,
            repoRootPath: repoRootPath,
            repoLabel: repoLabel,
            checkpoints: state.checkpoints,
            currentCheckpointPosition: state.currentCheckpointPosition,
            selectedCheckpointID: selectedCheckpointID
        )
    }

    private func refreshSelectedCodeTrackingState() async {
        guard let sessionID = selectedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            selectedCodeTrackingState = nil
            selectedCodeReviewPanelState = nil
            return
        }
        await refreshCodeTrackingState(for: sessionID)
    }

    private func refreshCodeTrackingState(for sessionID: String) async {
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionID.isEmpty else { return }

        var state = effectiveCodeTrackingState(for: normalizedSessionID)
        if !settings.assistantTrackCodeChangesInGitRepos {
            state.availability = .disabled
            publishCodeTrackingState(state)
            return
        }

        guard let repository = await resolvedTrackedCodeRepository(
            for: normalizedSessionID,
            fallbackState: state
        ) else {
            state.availability = .unavailable
            publishCodeTrackingState(state)
            return
        }

        state.availability = .available
        state.repoRootPath = repository.rootPath
        state.repoLabel = repository.label
        if !runtime.hasActiveTurn,
           pendingCodeCheckpointBaselinesBySessionID[normalizedSessionID] == nil,
           markIdleCodeCheckpointRecoveryAttemptIfNeeded(for: normalizedSessionID) {
            if await recoverIncompleteTrackedCodeCheckpointsIfNeeded(
                for: normalizedSessionID,
                repository: repository,
                turnID: nil,
                status: nil
            ) {
                return
            }
        }
        state.currentCheckpointPosition = min(
            state.currentCheckpointPosition,
            state.checkpoints.count - 1
        )
        publishCodeTrackingState(state)
    }

    private func resolvedTrackedCodeRepository(
        for sessionID: String,
        fallbackState: AssistantCodeTrackingState?
    ) async -> GitCheckpointRepositoryContext? {
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionID.isEmpty else { return nil }

        if let cwd = resolvedSessionCWD(for: normalizedSessionID),
           let repository = try? await gitCheckpointService.repositoryContext(for: cwd) {
            return repository
        }

        if let savedRepoRootPath = fallbackState?.repoRootPath,
           let repository = try? await gitCheckpointService.repositoryContext(for: savedRepoRootPath) {
            return repository
        }

        if let catalogCWD = await resolvedSessionCWDFromCatalog(for: normalizedSessionID),
           let repository = try? await gitCheckpointService.repositoryContext(for: catalogCWD) {
            return repository
        }

        return nil
    }

    private func resolvedSessionCWDFromCatalog(for sessionID: String) async -> String? {
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionID.isEmpty else { return nil }

        if let cached = sessionCatalogCWDCacheBySessionID[normalizedSessionID] {
            if !cached.isExpired {
                return cached.cwd
            }
            sessionCatalogCWDCacheBySessionID.removeValue(forKey: normalizedSessionID)
        }

        let loadedSessions = try? await sessionCatalog.loadSessions(
            limit: 1,
            preferredThreadID: normalizedSessionID,
            sessionIDs: [normalizedSessionID]
        )
        let cwd = loadedSessions?.first.flatMap { $0.effectiveCWD ?? $0.cwd }
        sessionCatalogCWDCacheBySessionID[normalizedSessionID] = SessionCatalogCWDCacheEntry(
            cwd: cwd,
            expiresAt: Date().addingTimeInterval(
                cwd == nil
                    ? Self.trackedCodeRecoveryCatalogCacheFailureTTL
                    : Self.trackedCodeRecoveryCatalogCacheSuccessTTL
            )
        )
        return cwd
    }

    private func truncatingFutureTrackedCodeCheckpointsIfNeeded(
        _ state: AssistantCodeTrackingState,
        repositoryRootPath: String
    ) async -> AssistantCodeTrackingState {
        guard state.currentCheckpointPosition + 1 < state.checkpoints.count else {
            return state
        }

        let removalRange = (state.currentCheckpointPosition + 1)..<state.checkpoints.count
        let removedCheckpoints = Array(state.checkpoints[removalRange])
        await deleteTrackedCodeCheckpointArtifacts(
            sessionID: state.sessionID,
            checkpointIDs: removedCheckpoints.map(\.id),
            repositoryRootPath: repositoryRootPath,
            checkpoints: removedCheckpoints
        )

        var updatedState = state
        updatedState.checkpoints.removeSubrange(removalRange)
        return updatedState
    }

    private func deleteTrackedCodeCheckpointArtifacts(
        sessionID: String,
        checkpointIDs: [String],
        repositoryRootPath: String,
        checkpoints: [AssistantCodeCheckpointSummary],
        additionalRefs: [String] = []
    ) async {
        let refs = checkpoints.flatMap { checkpoint in
            [
                checkpoint.beforeSnapshot.worktreeRef,
                checkpoint.beforeSnapshot.indexRef,
                checkpoint.afterSnapshot.worktreeRef,
                checkpoint.afterSnapshot.indexRef
            ]
        } + additionalRefs
        if !refs.isEmpty {
            await gitCheckpointService.deleteRefs(
                for: refs,
                repositoryRootPath: repositoryRootPath
            )
        }
        clearPendingConversationCheckpointCaptureTasks(
            sessionID: sessionID,
            checkpointIDs: checkpointIDs
        )
        conversationCheckpointStore.deleteCheckpoints(
            sessionID: sessionID,
            checkpointIDs: checkpointIDs
        )
    }

    private func conversationCheckpointCaptureTaskKey(
        sessionID: String,
        checkpointID: String,
        phase: AssistantCodeCheckpointPhase
    ) -> String {
        "\(sessionID.lowercased())|\(checkpointID.lowercased())|\(phase.rawValue)"
    }

    private func scheduleConversationCheckpointCapture(
        sessionID: String,
        checkpointID: String,
        phase: AssistantCodeCheckpointPhase
    ) {
        let key = conversationCheckpointCaptureTaskKey(
            sessionID: sessionID,
            checkpointID: checkpointID,
            phase: phase
        )
        pendingConversationCheckpointCaptureTasksByKey[key]?.cancel()
        flushPersistedHistoryIfNeeded(sessionID: sessionID)

        let checkpointStore = conversationCheckpointStore
        pendingConversationCheckpointCaptureTasksByKey[key] = Task.detached(priority: .utility) {
            do {
                try await checkpointStore.captureSnapshot(
                    sessionID: sessionID,
                    checkpointID: checkpointID,
                    phase: phase
                )
                CrashReporter.logInfo(
                    "Tracked coding saved \(phase.rawValue) conversation snapshot sessionID=\(sessionID) checkpointID=\(checkpointID)"
                )
            } catch {
                CrashReporter.logWarning(
                    "Tracked coding \(phase.rawValue) conversation snapshot failed sessionID=\(sessionID) checkpointID=\(checkpointID) error=\(error.localizedDescription)"
                )
            }
        }
    }

    private func waitForPendingConversationCheckpointCapture(
        sessionID: String,
        checkpointID: String,
        phase: AssistantCodeCheckpointPhase
    ) async throws {
        let key = conversationCheckpointCaptureTaskKey(
            sessionID: sessionID,
            checkpointID: checkpointID,
            phase: phase
        )
        guard let task = pendingConversationCheckpointCaptureTasksByKey[key] else {
            return
        }
        await task.value
        pendingConversationCheckpointCaptureTasksByKey.removeValue(forKey: key)
    }

    private func clearPendingConversationCheckpointCaptureTasks(
        sessionID: String,
        checkpointIDs: [String]
    ) {
        for checkpointID in checkpointIDs {
            for phase in [AssistantCodeCheckpointPhase.before, .after] {
                let key = conversationCheckpointCaptureTaskKey(
                    sessionID: sessionID,
                    checkpointID: checkpointID,
                    phase: phase
                )
                pendingConversationCheckpointCaptureTasksByKey[key]?.cancel()
                pendingConversationCheckpointCaptureTasksByKey.removeValue(forKey: key)
            }
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
        pendingConversationSnapshotSaveWorkItems[normalizedSessionID]?.cancel()
        pendingConversationSnapshotSaveWorkItems.removeValue(forKey: normalizedSessionID)
        dirtyConversationSnapshotSessionIDs.remove(normalizedSessionID)
        if !isProviderIndependentThreadV2(sessionID: normalizedSessionID) {
            sessionCatalog.saveNormalizedTimeline([], for: normalizedSessionID)
        }
        pendingResumeContextSnapshotsBySessionID.removeValue(forKey: normalizedSessionID)
        pendingResumeContextMetadataBySessionID.removeValue(forKey: normalizedSessionID)
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

    private func reloadAfterCodeCheckpointRestore(for sessionID: String) async {
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionID.isEmpty else { return }

        invalidateSessionHistoryCaches(for: normalizedSessionID)
        await refreshVisibleSessionSummaryIfNeeded(for: normalizedSessionID)
        if sessionsMatch(selectedSessionID, normalizedSessionID) {
            await reloadSelectedSessionHistoryIfNeeded(force: true)
        }
        refreshEditableTurns(for: normalizedSessionID)
        refreshMemoryState(for: normalizedSessionID)
        reloadMemoryInspectorSnapshot(closeIfMissing: true)
    }

    private func refreshVisibleSessionSummaryIfNeeded(for sessionID: String) async {
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionID.isEmpty else { return }

        let currentSource = sessions.first(where: { sessionsMatch($0.id, normalizedSessionID) })?.source

        if currentSource == .openAssist {
            let loadedSessions = await loadOpenAssistSessions(
                managedSessionIDs: Set([normalizedSessionID.lowercased()])
            )
            guard let loadedSession = loadedSessions.first(where: {
                sessionsMatch($0.id, normalizedSessionID)
            }) else {
                return
            }

            if let existingIndex = sessions.firstIndex(where: { sessionsMatch($0.id, normalizedSessionID) }) {
                sessions[existingIndex] = loadedSession
            } else {
                sessions.insert(loadedSession, at: 0)
            }
            persistManagedSessionsSnapshot()
            return
        }

        if currentSource == .cli {
            let loadedCopilotSessions = await loadManagedCopilotSessions(
                limit: max(40, sessions.count + 20),
                managedSessionIDs: Set([normalizedSessionID.lowercased()])
            )
            guard let loadedSession = loadedCopilotSessions.first(where: {
                sessionsMatch($0.id, normalizedSessionID)
            }) else {
                return
            }

            if let existingIndex = sessions.firstIndex(where: { sessionsMatch($0.id, normalizedSessionID) }) {
                sessions[existingIndex] = loadedSession
            } else {
                sessions.insert(loadedSession, at: 0)
            }
            persistManagedSessionsSnapshot()
            return
        }

        do {
            let loadedSessions = try await sessionCatalog.loadSessions(
                limit: 1,
                preferredThreadID: normalizedSessionID,
                preferredCWD: nil,
                sessionIDs: [normalizedSessionID]
            )
            guard let loadedSession = applyStoredSessionMetadata(to: loadedSessions).first else {
                return
            }

            sessionCatalogCWDCacheBySessionID[normalizedSessionID] = SessionCatalogCWDCacheEntry(
                cwd: loadedSession.effectiveCWD ?? loadedSession.cwd,
                expiresAt: Date().addingTimeInterval(Self.trackedCodeRecoveryCatalogCacheSuccessTTL)
            )

            if let existingIndex = sessions.firstIndex(where: { sessionsMatch($0.id, normalizedSessionID) }) {
                sessions[existingIndex] = loadedSession
            } else {
                sessions.insert(loadedSession, at: 0)
            }
        } catch {
            CrashReporter.logWarning(
                "Tracked coding session summary refresh failed sessionID=\(normalizedSessionID) error=\(error.localizedDescription)"
            )
        }
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
                sessions = applyStoredSessionMetadata(to: sessions)
            }
            refreshMemoryInspectorIfNeeded(
                affectedThreadIDs: [sessionID],
                affectedProjectIDs: [project.id]
            )
        } catch {
            CrashReporter.logError("Project digest reconciliation failed: \(error.localizedDescription)")
        }
    }

    private func commitPendingHistoryEditIfNeeded(for sessionID: String) async {
        guard let branch = historyBranchState,
              sessionsMatch(branch.sessionID, sessionID) else {
            return
        }

        let visibleAnchorIDs = (try? threadRewriteService.editableTurns(sessionID: branch.sessionID).map(\.anchorID)) ?? []
        try? threadMemoryService.deleteCheckpoints(
            for: branch.sessionID,
            retaining: Set(visibleAnchorIDs)
        )

        let startingTrackingState = effectiveCodeTrackingState(for: branch.sessionID)
        if let repoRootPath = startingTrackingState.repoRootPath {
            var updatedTrackingState = await truncatingFutureTrackedCodeCheckpointsIfNeeded(
                startingTrackingState,
                repositoryRootPath: repoRootPath
            )
            updatedTrackingState.historyBranchState = nil
            publishCodeTrackingState(updatedTrackingState)
        } else {
            clearPersistedHistoryBranchState(
                for: branch.sessionID,
                currentTrackingState: startingTrackingState
            )
        }

        deleteHistorySnapshots(
            sessionID: branch.sessionID,
            snapshotIDs: branch.futureStates.map(\.snapshotID)
        )
        historyBranchState = nil
        refreshEditableTurns(for: branch.sessionID)
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

    private func trackedCodeTouchedPaths(
        for sessionID: String,
        turnID: String?,
        startedAt: Date?,
        repositoryRootPath: String
    ) -> Set<String> {
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionID.isEmpty else { return [] }

        let normalizedTurnID = turnID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let sessionTimeline = timelineItemsBySessionID[normalizedSessionID] ?? timelineItems
        let sessionCWD = resolvedSessionCWD(for: normalizedSessionID)

        let paths = sessionTimeline.compactMap(\.activity)
            .filter { activity in
                switch activity.kind {
                case .fileChange, .commandExecution:
                    break
                default:
                    return false
                }

                if let normalizedTurnID {
                    return activity.turnID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty == normalizedTurnID
                }
                if let startedAt {
                    return activity.updatedAt >= startedAt || activity.startedAt >= startedAt
                }
                return true
            }
            .flatMap {
                assistantRepoRelativeFilePathCandidates(
                    from: $0.rawDetails,
                    sessionCWD: sessionCWD,
                    repositoryRootPath: repositoryRootPath
                )
            }

        return Set(paths)
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
        return sessions.first(where: { sessionsMatch($0.id, selectedSessionID) })
    }

    struct ResolvedSessionConfiguration: Equatable {
        let modelID: String?
        let taskMode: AssistantTaskMode
        let interactionMode: AssistantInteractionMode
        let reasoningEffort: AssistantReasoningEffort
        let fastModeEnabled: Bool
    }

    static func normalizedStartupPreferredModelID(
        for backend: AssistantRuntimeBackend,
        storedModelID: String?
    ) -> String? {
        let normalizedModelID = storedModelID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
        if backend == .ollamaLocal {
            return normalizedModelID ?? AssistantGemma4ModelCatalog.recommendedModelID()
        }
        guard backend == .claudeCode else { return normalizedModelID }

        switch normalizedModelID?.lowercased() {
        case nil, "sonnet":
            return "opus"
        default:
            return normalizedModelID
        }
    }

    static func resolvedModelSelection(
        from session: AssistantSessionSummary?,
        backend: AssistantRuntimeBackend,
        availableModels: [AssistantModelOption],
        preferredModelID: String?,
        surfaceModelID: String? = nil
    ) -> String? {
        let visibleModels = selectableModels(for: backend, from: availableModels)
        guard !visibleModels.isEmpty else { return nil }

        let visibleModelIDs = Set(visibleModels.map(\.id))
        let normalizedPreferredModelID = preferredModelID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
        let normalizedSurfaceModelID = surfaceModelID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
        let bindingModelID = session?
            .providerBinding(for: backend)?
            .latestModelID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
        let sessionModelID = session?
            .modelID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty

        let candidateModelIDs: [String?]
        if session?.isProviderIndependentThreadV2 == true {
            candidateModelIDs = [
                bindingModelID,
                normalizedSurfaceModelID,
                visibleModels.first(where: \.isDefault)?.id,
                visibleModels.first?.id
            ]
        } else {
            candidateModelIDs = [
                sessionModelID,
                normalizedSurfaceModelID,
                normalizedPreferredModelID,
                visibleModels.first(where: \.isDefault)?.id,
                visibleModels.first?.id
            ]
        }

        for candidate in candidateModelIDs {
            guard let candidate,
                  visibleModelIDs.contains(candidate) else {
                continue
            }
            return candidate
        }

        return nil
    }

    static func selectableModels(
        for backend: AssistantRuntimeBackend,
        from availableModels: [AssistantModelOption]
    ) -> [AssistantModelOption] {
        let unhiddenModels = availableModels.filter { !$0.hidden }
        guard backend == .ollamaLocal else {
            return unhiddenModels
        }

        return unhiddenModels.filter(\.isInstalled)
    }

    static func resolvedSessionConfiguration(
        from session: AssistantSessionSummary?,
        backend: AssistantRuntimeBackend,
        availableModels: [AssistantModelOption],
        preferredModelID: String?,
        surfaceModelID: String? = nil
    ) -> ResolvedSessionConfiguration {
        let resolvedModelID = resolvedModelSelection(
            from: session,
            backend: backend,
            availableModels: availableModels,
            preferredModelID: preferredModelID,
            surfaceModelID: surfaceModelID
        )
        let activeBinding = session.flatMap { summary -> AssistantProviderBinding? in
            guard summary.isProviderIndependentThreadV2,
                  let activeProvider = summary.activeProviderBackend else {
                return nil
            }
            return summary.providerBinding(for: activeProvider)
        }

        return ResolvedSessionConfiguration(
            modelID: resolvedModelID,
            taskMode: session?.latestTaskMode ?? .chat,
            interactionMode: (activeBinding?.latestInteractionMode
                ?? session?.latestInteractionMode
                ?? .agentic).normalizedForActiveUse,
            reasoningEffort: activeBinding?.latestReasoningEffort
                ?? session?.latestReasoningEffort
                ?? .high,
            fastModeEnabled: (activeBinding?.latestServiceTier
                ?? session?.latestServiceTier)?.caseInsensitiveCompare("fast") == .orderedSame
        )
    }

    static func configurationModels(
        for backend: AssistantRuntimeBackend,
        visibleProviderSurfaceBackend: AssistantRuntimeBackend?,
        visibleAvailableModels: [AssistantModelOption],
        cachedProviderModels: [AssistantModelOption]
    ) -> [AssistantModelOption] {
        if visibleProviderSurfaceBackend == backend {
            return visibleAvailableModels
        }
        return cachedProviderModels
    }

    private func restoreSessionConfiguration(from session: AssistantSessionSummary?) {
        guard let session else { return }

        isRestoringSessionConfiguration = true
        defer { isRestoringSessionConfiguration = false }

        let providerBackend = backend(for: session)
        let configurationModels = Self.configurationModels(
            for: providerBackend,
            visibleProviderSurfaceBackend: visibleProviderSurfaceBackend,
            visibleAvailableModels: availableModels,
            cachedProviderModels: cachedAvailableModels(
                threadID: session.id,
                backend: providerBackend
            )
        )

        let resolvedConfiguration = Self.resolvedSessionConfiguration(
            from: session,
            backend: providerBackend,
            availableModels: configurationModels,
            preferredModelID: settings.assistantPreferredModelID.nonEmpty,
            surfaceModelID: providerSurfaceSnapshot(
                threadID: session.id,
                backend: providerBackend
            )?.selectedModelID
        )

        selectedModelID = resolvedConfiguration.modelID
        runtime.setPreferredModelID(resolvedConfiguration.modelID)
        runtimeHealth.selectedModelID = resolvedConfiguration.modelID
        taskMode = resolvedConfiguration.taskMode
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
        sessions[sessionIndex].latestTaskMode = taskMode
        sessions[sessionIndex].latestInteractionMode = interactionMode
        sessions[sessionIndex].latestReasoningEffort = reasoningEffort
        sessions[sessionIndex].latestServiceTier = fastModeEnabled ? "fast" : nil
        if sessions[sessionIndex].isProviderIndependentThreadV2,
           let activeBackend = sessions[sessionIndex].activeProviderBackend {
            var binding = sessions[sessionIndex].providerBinding(for: activeBackend)
                ?? AssistantProviderBinding(backend: activeBackend)
            binding.latestModelID = selectedModelID
            binding.latestInteractionMode = interactionMode
            binding.latestReasoningEffort = reasoningEffort
            binding.latestServiceTier = fastModeEnabled ? "fast" : nil
            sessions[sessionIndex].setProviderBinding(binding)
            updateProviderSurfaceSnapshot(threadID: sessionID, backend: activeBackend) { snapshot in
                snapshot.selectedModelID = selectedModelID
            }
        }
        persistManagedSessionsSnapshot()
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
        Continue from the latest user intent and recent assistant state. Do not repeat work that these notes show is already completed unless the user asks to revisit it.
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

    struct ProviderRecoveryHandoffRequest: Equatable {
        let summarySeed: String
        let recentTurns: [PromptRewriteConversationTurn]
        let context: PromptRewriteConversationContext
        let metadata: [String: String]
    }

    struct ProviderRecoveryResumeContextResult: Equatable {
        let text: String?
        let metadata: [String: String]
    }

    static func buildProviderRecoveryHandoffRequest(
        transcriptEntries: [AssistantTranscriptEntry],
        timelineItems: [AssistantTimelineItem],
        sessionSummary: AssistantSessionSummary?,
        maxMeaningfulEntries: Int = 30
    ) -> ProviderRecoveryHandoffRequest? {
        let recentTurns = buildProviderRecoveryPromptTurns(
            from: transcriptEntries,
            maxMeaningfulEntries: maxMeaningfulEntries
        )
        let prioritizedImageAnswer = latestImageDerivedAnswer(in: timelineItems)

        var sections: [String] = [
            "# Provider Recovery Context",
            "The original provider session could not be reopened. This summary will help a fresh provider session continue the same Open Assist chat."
        ]

        let sessionTitle = sessionSummary?.title.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let sessionSummaryText = sessionSummary?.summary?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let latestUserMessage = latestMeaningfulRecoveryUserText(
            in: recentTurns,
            fallback: sessionSummary?.latestUserMessage
        )
        let hasRecoverySignal = !recentTurns.isEmpty
            || prioritizedImageAnswer != nil
            || sessionTitle != nil
            || sessionSummaryText != nil
            || latestUserMessage != nil
        guard hasRecoverySignal else { return nil }

        if sessionTitle != nil || sessionSummaryText != nil || latestUserMessage != nil {
            sections.append("")
            sections.append("## Saved Thread Metadata")
            if let sessionTitle {
                sections.append("- Title: \(sessionTitle)")
            }
            if let sessionSummaryText {
                sections.append("- Saved summary: \(sessionSummaryText)")
            }
            if let latestUserMessage {
                sections.append("- Latest user request before fallback: \(latestUserMessage)")
            }
        }

        if let prioritizedImageAnswer {
            sections.append("")
            sections.append("## Important Screenshot-Derived Answer")
            if let userText = prioritizedImageAnswer.userText?.nonEmpty {
                sections.append("- User prompt: \(userText)")
            }
            sections.append("- Assistant answer: \(prioritizedImageAnswer.assistantText)")
        }

        sections.append("")
        sections.append("## Recovery Goal")
        sections.append("- Continue the current task without asking the user to repeat older context unless something is truly missing.")
        sections.append("- Preserve named entities, numbered lists, prior decisions, open questions, and screenshot-derived facts already established.")

        let summarySeed = providerRecoverySummarySeed(
            sections: sections,
            limit: 2_600
        )
        let context = providerRecoveryConversationContext(for: sessionSummary)

        var metadata: [String: String] = [
            "recovery_recent_turn_count": "\(recentTurns.count)",
            "recovery_recent_entry_limit": "\(maxMeaningfulEntries)",
            "recovery_has_saved_thread_summary": sessionSummaryText == nil ? "false" : "true",
            "recovery_included_image_answer": prioritizedImageAnswer == nil ? "false" : "true"
        ]
        if let sessionID = sessionSummary?.id.nonEmpty {
            metadata["recovery_thread_id"] = sessionID
        }
        if let sessionTitle {
            metadata["recovery_thread_title"] = normalizedResumeContextSnippet(sessionTitle, limit: 120)
        }

        guard summarySeed.nonEmpty != nil || !recentTurns.isEmpty else {
            return nil
        }

        return ProviderRecoveryHandoffRequest(
            summarySeed: summarySeed,
            recentTurns: recentTurns,
            context: context,
            metadata: metadata
        )
    }

    static func buildProviderRecoveryResumeContext(
        transcriptEntries: [AssistantTranscriptEntry],
        timelineItems: [AssistantTimelineItem],
        sessionSummary: AssistantSessionSummary?,
        rewriteProvider: MemoryRewriteExtractionProviding = StubMemoryRewriteExtractionProvider.shared,
        timeoutSeconds: Int = 6
    ) async -> ProviderRecoveryResumeContextResult {
        let localFallback = buildResumeContext(
            transcriptEntries: transcriptEntries,
            sessionSummary: sessionSummary
        )

        guard let request = buildProviderRecoveryHandoffRequest(
            transcriptEntries: transcriptEntries,
            timelineItems: timelineItems,
            sessionSummary: sessionSummary
        ) else {
            return ProviderRecoveryResumeContextResult(
                text: localFallback,
                metadata: [
                    "recovery_summary_method": "local-short-fallback",
                    "recovery_summary_timeout_seconds": "\(timeoutSeconds)",
                    "recovery_used_deterministic_fallback": "true"
                ]
            )
        }

        let response = await rewriteProvider.summarizeConversationHandoff(
            summarySeed: request.summarySeed,
            recentTurns: request.recentTurns,
            context: request.context,
            timeoutSeconds: timeoutSeconds,
            style: .providerRecovery
        )

        let normalizedMethod = MemoryTextNormalizer.collapsedWhitespace(response.method)
        let normalizedText = normalizedProviderRecoverySummaryText(response.text, limit: 1_800)
        let resolvedText = normalizedText.nonEmpty ?? localFallback
        let usedDeterministicFallback = !normalizedMethod.lowercased().hasPrefix("ai")

        var metadata = request.metadata
        metadata["recovery_summary_method"] = normalizedMethod.isEmpty
            ? "deterministic-fallback"
            : normalizedMethod
        metadata["recovery_summary_timeout_seconds"] = "\(timeoutSeconds)"
        metadata["recovery_used_deterministic_fallback"] = usedDeterministicFallback ? "true" : "false"
        if let confidence = response.confidence {
            metadata["recovery_summary_confidence"] = String(format: "%.3f", max(0, min(1, confidence)))
        }

        return ProviderRecoveryResumeContextResult(
            text: resolvedText,
            metadata: metadata
        )
    }

    private func preferredSessionID(preferConversationContent: Bool = true) -> String? {
        let sourceSessions = visibleSidebarSessions
        if preferConversationContent,
           let session = sourceSessions.first(where: { $0.hasConversationContent }) {
            return session.id
        }
        return sourceSessions.first?.id ?? sessions.first(where: {
            !$0.isArchived && assistantSessionSupportsCurrentThreadUI($0)
        })?.id
    }

    private func normalizedArchiveRetentionHours(_ hours: Int) -> Int {
        min(24 * 365, max(1, hours))
    }

    private func archiveRetentionDescription(hours: Int) -> String {
        if hours % (24 * 30) == 0 {
            let months = max(1, hours / (24 * 30))
            return months == 1 ? "1 month" : "\(months) months"
        }
        if hours % (24 * 7) == 0 {
            let weeks = max(1, hours / (24 * 7))
            return weeks == 1 ? "1 week" : "\(weeks) weeks"
        }
        if hours % 24 == 0 {
            let days = max(1, hours / 24)
            return days == 1 ? "1 day" : "\(days) days"
        }
        return hours == 1 ? "1 hour" : "\(hours) hours"
    }

    private func prepareSessionForPrompt() async throws -> String {
        if let selectedSessionID = selectedSessionID?.nonEmpty {
            let selectedRuntime = ensureRuntime(for: selectedSessionID)
            let selectedSession = sessions.first(where: { sessionsMatch($0.id, selectedSessionID) })

            if let selectedSession,
               selectedSession.isCanonicalThread {
                let providerBackend = backend(for: selectedSession)
                await ensureRuntimeBackend(selectedRuntime, matches: providerBackend)
                try ensureLiveRuntimeCapacity(for: selectedSessionID)

                if let providerSessionID = providerSessionID(for: selectedSession) {
                    if let currentSessionID = selectedRuntime.currentSessionID?.nonEmpty,
                       sessionsMatch(currentSessionID, providerSessionID) {
                        do {
                            try await selectedRuntime.refreshCurrentSessionConfiguration(
                                cwd: resolvedSessionCWD(for: selectedSessionID),
                                preferredModelID: selectedModelID
                            )
                        } catch {
                            if isMissingRolloutError(error) {
                                return try await recoverMissingRollout(for: selectedSessionID)
                            }
                            if await recoverStoredProviderSessionIfNeeded(
                                after: error,
                                threadID: selectedSessionID,
                                backend: providerBackend
                            ) {
                                return selectedSessionID
                            }
                            throw error
                        }
                        return selectedSessionID
                    }

                    do {
                        try await selectedRuntime.resumeSession(
                            providerSessionID,
                            cwd: resolvedSessionCWD(for: selectedSessionID),
                            preferredModelID: selectedModelID
                        )
                        updateProviderLink(
                            forThreadID: selectedSessionID,
                            backend: providerBackend,
                            providerSessionID: selectedRuntime.currentSessionID ?? providerSessionID
                        )
                        markPendingResumeContext(for: selectedSessionID)
                        return selectedSessionID
                    } catch {
                        if isMissingRolloutError(error) {
                            return try await recoverMissingRollout(for: selectedSessionID)
                        }
                        if await recoverStoredProviderSessionIfNeeded(
                            after: error,
                            threadID: selectedSessionID,
                            backend: providerBackend
                        ) {
                            return selectedSessionID
                        }
                        throw error
                    }
                }

                let startedProviderSessionID = try await selectedRuntime.startNewSession(
                    cwd: resolvedSessionCWD(for: selectedSessionID),
                    preferredModelID: selectedModelID
                )
                updateProviderLink(
                    forThreadID: selectedSessionID,
                    backend: providerBackend,
                    providerSessionID: startedProviderSessionID
                )
                markPendingResumeContext(for: selectedSessionID)
                return selectedSessionID
            }

            if let currentSessionID = selectedRuntime.currentSessionID?.nonEmpty {
                if sessionsMatch(currentSessionID, selectedSessionID) {
                    if !isPendingFreshSession(currentSessionID) {
                        do {
                            try await selectedRuntime.refreshCurrentSessionConfiguration(
                                cwd: resolvedSessionCWD(for: currentSessionID),
                                preferredModelID: selectedModelID
                            )
                        } catch {
                            if isMissingRolloutError(error) {
                                return try await recoverMissingRollout(for: selectedSessionID)
                            }
                            if await recoverStoredProviderSessionIfNeeded(
                                after: error,
                                threadID: selectedSessionID,
                                backend: selectedSession.map { backend(for: $0) } ?? assistantBackend
                            ) {
                                return selectedSessionID
                            }
                            throw error
                        }
                    }
                    return currentSessionID
                }
            }

            try ensureLiveRuntimeCapacity(for: selectedSessionID)

            if isPendingFreshSession(selectedSessionID) {
                let replacementSessionID = try await selectedRuntime.startNewSession(
                    cwd: resolvedSessionCWD(for: selectedSessionID),
                    preferredModelID: selectedModelID
                )
                discardPendingFreshSession(selectedSessionID)
                markPendingFreshSession(replacementSessionID, source: assistantBackend.sessionSource)
                moveRuntimeRegistration(
                    from: selectedSessionID,
                    to: replacementSessionID,
                    runtime: selectedRuntime
                )
                return replacementSessionID
            }

            if let selectedSession {
                do {
                    try await selectedRuntime.resumeSession(
                        selectedSession.id,
                        cwd: resolvedSessionCWD(for: selectedSession.id),
                        preferredModelID: selectedModelID
                    )
                    markPendingResumeContext(for: selectedSession.id)
                    return selectedSession.id
                } catch {
                    if isMissingRolloutError(error) {
                        return try await recoverMissingRollout(for: selectedSession.id)
                    }
                    if await recoverStoredProviderSessionIfNeeded(
                        after: error,
                        threadID: selectedSession.id,
                        backend: backend(for: selectedSession)
                    ) {
                        return selectedSession.id
                    }
                    throw error
                }
            }
        }

        let sessionID = createOpenAssistThread(isTemporary: false)
        selectedSessionID = sessionID
        transcriptSessionID = sessionID
        timelineSessionID = sessionID
        ensureSessionVisible(sessionID)
        return try await prepareSessionForPrompt()
    }

    private static func fallbackVisibleProject(
        afterHiding hiddenProjectID: String,
        in projects: [AssistantProject]
    ) -> AssistantProject? {
        let normalizedHiddenProjectID = hiddenProjectID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !projects.isEmpty else { return nil }

        if let hiddenIndex = projects.firstIndex(where: {
            $0.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedHiddenProjectID
        }) {
            let laterProjects = projects.suffix(from: projects.index(after: hiddenIndex))
            if let nextVisible = laterProjects.first(where: { !$0.isHidden }) {
                return nextVisible
            }

            let earlierProjects = projects.prefix(hiddenIndex).reversed()
            if let previousVisible = earlierProjects.first(where: { !$0.isHidden }) {
                return previousVisible
            }
        }

        return projects.first(where: { !$0.isHidden })
    }
    private func reloadSelectedSessionHistoryIfNeeded(force: Bool = false) async {
        guard let selectedSessionID,
              let selectedSession,
              selectedSession.supportsCatalogHistory else {
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
            let recentChunk = await loadRecentHistoryChunk(
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

        let previousCachedTimelineCount = timelineItemsBySessionID[selectedSessionID]?.count ?? 0
        let previousCachedTranscriptCount = transcriptEntriesBySessionID[selectedSessionID]?.count ?? 0
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

        // If the merge didn't add any items beyond what was already cached
        // in memory, the store has no additional history to offer. Clear the
        // optimistic canLoadMore flag so the UI doesn't show a stale button.
        if mergedTimeline.count <= previousCachedTimelineCount,
           mergedTranscript.count <= previousCachedTranscriptCount {
            canLoadMoreHistoryBySessionID[selectedSessionID] = false
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

    private func markPendingResumeContext(for sessionID: String?) {
        guard let normalizedSessionID = normalizedSessionID(sessionID) else { return }
        pendingResumeContextSessionIDs.insert(normalizedSessionID)
        if let snapshot = buildResumeContextSnapshot(for: normalizedSessionID)?.nonEmpty {
            pendingResumeContextSnapshotsBySessionID[normalizedSessionID] = snapshot
            pendingResumeContextMetadataBySessionID.removeValue(forKey: normalizedSessionID)
        } else {
            pendingResumeContextSnapshotsBySessionID.removeValue(forKey: normalizedSessionID)
            pendingResumeContextMetadataBySessionID.removeValue(forKey: normalizedSessionID)
        }
    }

    func loadMoreHistoryForSelectedSession() async -> Bool {
        guard let selectedSessionID = selectedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
              let selectedSession,
              selectedSession.supportsCatalogHistory else {
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

    private func buildProviderRecoveryResumeContextSnapshot(
        for sessionID: String?
    ) async -> ProviderRecoveryResumeContextResult {
        guard let normalizedSessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return ProviderRecoveryResumeContextResult(
                text: nil,
                metadata: [
                    "recovery_summary_method": "local-short-fallback",
                    "recovery_used_deterministic_fallback": "true"
                ]
            )
        }

        let history = await loadProviderRecoveryHistory(for: normalizedSessionID)
        let summary = sessions.first(where: { sessionsMatch($0.id, normalizedSessionID) })
        let result = await Self.buildProviderRecoveryResumeContext(
            transcriptEntries: history.transcript,
            timelineItems: history.timeline,
            sessionSummary: summary
        )

        let method = result.metadata["recovery_summary_method"]?.lowercased() ?? "unknown"
        if !method.hasPrefix("ai") {
            CrashReporter.logWarning(
                "Provider recovery resume context used deterministic fallback threadID=\(normalizedSessionID) method=\(method)"
            )
        }
        return result
    }

    private func loadProviderRecoveryHistory(for sessionID: String) async -> SessionHistorySlice {
        let transcriptLimit = 480
        let timelineLimit = 480

        let cachedTranscript = transcriptEntriesBySessionID[sessionID]
            ?? (sessionsMatch(transcriptSessionID, sessionID) ? transcript : [])
        let cachedTimeline = timelineItemsBySessionID[sessionID]
            ?? (sessionsMatch(timelineSessionID, sessionID) ? timelineItems : [])

        async let persistedTranscriptTask = loadPersistedTranscript(
            sessionID: sessionID,
            limit: transcriptLimit
        )
        async let persistedTimelineTask = loadPersistedTimeline(
            sessionID: sessionID,
            limit: timelineLimit
        )
        let (persistedTranscript, persistedTimeline) = await (
            persistedTranscriptTask,
            persistedTimelineTask
        )

        return SessionHistorySlice(
            timeline: mergeTimelineHistory(persistedTimeline, with: cachedTimeline),
            transcript: mergeTranscriptHistory(persistedTranscript, with: cachedTranscript)
        )
    }

    private func recoverMissingRollout(for sessionID: String?) async throws -> String {
        let sourceSessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        lastStatusMessage = "Rebuilding thread context for the new Claude session..."
        let recoveredContextResult = await buildProviderRecoveryResumeContextSnapshot(for: sessionID)
        let recoveredContext = recoveredContextResult.text
        let sourceSession = sourceSessionID.flatMap { sessionID in
            sessions.first(where: { sessionsMatch($0.id, sessionID) })
        }
        let targetThreadID = sourceSession?.isCanonicalThread == true ? sourceSession?.id : sourceSessionID
        let recoveryRuntime = targetThreadID.map { ensureRuntime(for: $0) } ?? makeUnboundRuntime()
        let replacementSessionID = try await recoveryRuntime.startNewSession(
            cwd: targetThreadID.flatMap { resolvedSessionCWD(for: $0) },
            preferredModelID: selectedModelID
        )

        if let sourceSession,
           sourceSession.isCanonicalThread,
           let targetThreadID {
            updateProviderLink(
                forThreadID: targetThreadID,
                backend: backend(for: sourceSession),
                providerSessionID: replacementSessionID
            )
            moveRuntimeRegistration(
                from: sourceSessionID ?? sessionIDBoundToRuntime(recoveryRuntime),
                to: targetThreadID,
                runtime: recoveryRuntime
            )
            if let recoveredContext {
                pendingResumeContextSnapshotsBySessionID[targetThreadID] = recoveredContext
                pendingResumeContextMetadataBySessionID[targetThreadID] = recoveredContextResult.metadata
            }
            lastStatusMessage = "That saved provider session could not be reopened, so Open Assist started a fresh provider session inside the same chat."
            return targetThreadID
        }

        moveRuntimeRegistration(
            from: sourceSessionID ?? sessionIDBoundToRuntime(recoveryRuntime),
            to: replacementSessionID,
            runtime: recoveryRuntime
        )
        markPendingFreshSession(replacementSessionID, source: assistantBackend.sessionSource)
        recordOwnedSessionID(replacementSessionID)
        try? threadSkillStore.migrateBindings(from: sourceSessionID, to: replacementSessionID)
        if let recoveredContext {
            pendingResumeContextSnapshotsBySessionID[replacementSessionID] = recoveredContext
            pendingResumeContextMetadataBySessionID[replacementSessionID] = recoveredContextResult.metadata
        }
        lastStatusMessage = "That saved thread could not be reopened, so Open Assist started a new thread with recovered context from the older chat."
        return replacementSessionID
    }

    private func isMissingRolloutError(_ error: Error) -> Bool {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !message.isEmpty else { return false }
        return message.contains("no rollout found for thread id")
            || message.contains("failed to load rollout")
    }

    private func shouldRecoverStoredProviderSession(
        after error: Error,
        threadID: String?,
        backend: AssistantRuntimeBackend
    ) -> Bool {
        guard let normalizedThreadID = normalizedSessionID(threadID),
              let session = sessions.first(where: { sessionsMatch($0.id, normalizedThreadID) }),
              session.isCanonicalThread,
              providerSessionID(for: session, backend: backend) != nil else {
            return false
        }

        return Self.isRecoverableProviderSessionErrorMessage(
            error.localizedDescription,
            backend: backend
        )
    }

    @discardableResult
    private func recoverStoredProviderSessionIfNeeded(
        after error: Error,
        threadID: String?,
        backend: AssistantRuntimeBackend,
        statusMessageOverride: String? = nil
    ) async -> Bool {
        guard shouldRecoverStoredProviderSession(
            after: error,
            threadID: threadID,
            backend: backend
        ),
        let normalizedThreadID = normalizedSessionID(threadID) else {
            return false
        }

        CrashReporter.logWarning(
            "Recovering stored provider session threadID=\(normalizedThreadID) backend=\(backend.rawValue) error=\(error.localizedDescription)"
        )

        do {
            _ = try await recoverMissingRollout(for: normalizedThreadID)
            if let statusMessageOverride = statusMessageOverride?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
                lastStatusMessage = statusMessageOverride
            }
            return true
        } catch {
            CrashReporter.logError(
                "Stored provider session recovery failed threadID=\(normalizedThreadID) backend=\(backend.rawValue) error=\(error.localizedDescription)"
            )
            return false
        }
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
        async let timelineTask = loadPersistedTimeline(
            sessionID: sessionID,
            limit: timelineLimit
        )
        async let transcriptTask = loadPersistedTranscript(
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
                planTurnIDs: cachedVisiblePlanTurnIDs
              ) else {
            return false
        }

        timelineItems = updatedItems
        timelineSessionID = sessionID
        if updatedItem.kind == .plan, let turnID = updatedItem.turnID?.assistantNonEmpty {
            cachedVisiblePlanTurnIDs.insert(turnID)
        }
        var updatedRenderItems = cachedRenderItems
        updatedRenderItems[updatedRenderItems.count - 1] = .timeline(updatedItem)
        cachedRenderItems = updatedRenderItems
        return true
    }

    private func setVisibleTimeline(_ items: [AssistantTimelineItem], for sessionID: String?) {
        timelineItems = items
        timelineSessionID = sessionID
        cachedVisiblePlanTurnIDs = planTurnIDsForVisibleTimeline(in: items)
        if let sessionID = sessionID?.nonEmpty {
            timelineItemsBySessionID[sessionID] = items
            persistConversationSnapshotIfNeeded(sessionID: sessionID)
        }
        rebuildRenderItemsCache()
    }

    private func setVisibleTranscript(_ entries: [AssistantTranscriptEntry], for sessionID: String?) {
        transcript = entries
        transcriptSessionID = sessionID
        if let sessionID = sessionID?.nonEmpty {
            transcriptEntriesBySessionID[sessionID] = entries
            persistConversationSnapshotIfNeeded(sessionID: sessionID)
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
        recordConversationMutationIfNeeded(sessionID: sessionID) { normalizedSessionID in
            try self.conversationStore.appendTranscriptUpsertEvent(
                threadID: normalizedSessionID,
                entry: entry
            )
        }
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
                isStreaming: isStreaming,
                providerBackend: existingEntry.providerBackend,
                providerModelID: existingEntry.providerModelID
            )
        } else {
            entries.append(
                annotatedTranscriptEntry(
                    AssistantTranscriptEntry(
                        id: id,
                        role: role,
                        text: delta,
                        createdAt: createdAt,
                        emphasis: emphasis,
                        isStreaming: isStreaming
                    ),
                    sessionID: sessionID
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
        let updatedEntry = entries.last(where: { $0.id == id })
        recordConversationMutationIfNeeded(sessionID: sessionID) { normalizedSessionID in
            try self.conversationStore.appendTranscriptAppendDeltaEvent(
                threadID: normalizedSessionID,
                id: id,
                role: role,
                delta: delta,
                createdAt: updatedEntry?.createdAt ?? createdAt,
                emphasis: emphasis,
                isStreaming: isStreaming,
                providerBackend: updatedEntry?.providerBackend,
                providerModelID: updatedEntry?.providerModelID
            )
        }
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

    private func annotatedTimelineItem(
        _ item: AssistantTimelineItem,
        sessionID: String?
    ) -> AssistantTimelineItem {
        switch item.kind {
        case .assistantProgress, .assistantFinal, .plan:
            break
        case .userMessage, .activity, .permission, .system:
            return item
        }

        guard let normalizedSessionID = normalizedSessionID(sessionID ?? item.sessionID),
              let session = sessions.first(where: { sessionsMatch($0.id, normalizedSessionID) }) else {
            return item
        }

        var annotated = item
        if annotated.providerBackend == nil {
            annotated.providerBackend = session.activeProviderBackend
        }
        if annotated.providerModelID == nil {
            annotated.providerModelID = session.modelID ?? selectedModelID
        }
        return annotated
    }

    private func annotatedTranscriptEntry(
        _ entry: AssistantTranscriptEntry,
        sessionID: String?
    ) -> AssistantTranscriptEntry {
        guard entry.providerBackend == nil,
              let normalizedSessionID = normalizedSessionID(sessionID),
              let session = sessions.first(where: { sessionsMatch($0.id, normalizedSessionID) }) else {
            return entry
        }

        return AssistantTranscriptEntry(
            id: entry.id,
            role: entry.role,
            text: entry.text,
            createdAt: entry.createdAt,
            emphasis: entry.emphasis,
            isStreaming: entry.isStreaming,
            providerBackend: session.activeProviderBackend,
            providerModelID: session.modelID ?? selectedModelID
        )
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

    private func isProviderIndependentThreadV2(sessionID: String?) -> Bool {
        guard let normalizedSessionID = normalizedSessionID(sessionID) else { return false }
        return sessions.first(where: { self.sessionsMatch($0.id, normalizedSessionID) })?.isProviderIndependentThreadV2 == true
    }

    /// Background queue for conversation store read operations (snapshot loading,
    /// timeline/transcript retrieval) so they don't block the main thread.
    private static let conversationReadQueue = DispatchQueue(
        label: "com.openassist.conversation.read",
        qos: .userInitiated
    )

    private func loadPersistedTranscript(
        sessionID: String,
        limit: Int
    ) async -> [AssistantTranscriptEntry] {
        if isProviderIndependentThreadV2(sessionID: sessionID) {
            let store = conversationStore
            return await withCheckedContinuation { continuation in
                Self.conversationReadQueue.async {
                    continuation.resume(returning: store.loadTranscript(threadID: sessionID, limit: limit))
                }
            }
        }
        return await sessionCatalog.loadTranscript(sessionID: sessionID, limit: limit)
    }

    private func loadPersistedTimeline(
        sessionID: String,
        limit: Int
    ) async -> [AssistantTimelineItem] {
        if isProviderIndependentThreadV2(sessionID: sessionID) {
            let store = conversationStore
            return await withCheckedContinuation { continuation in
                Self.conversationReadQueue.async {
                    continuation.resume(returning: store.loadTimeline(threadID: sessionID, limit: limit))
                }
            }
        }
        return await sessionCatalog.loadMergedTimeline(sessionID: sessionID, limit: limit)
    }

    private func loadRecentHistoryChunk(
        sessionID: String,
        timelineLimit: Int,
        transcriptLimit: Int
    ) async -> CodexSessionCatalog.SessionHistoryChunk {
        if isProviderIndependentThreadV2(sessionID: sessionID) {
            let store = conversationStore
            return await withCheckedContinuation { continuation in
                Self.conversationReadQueue.async {
                    continuation.resume(returning: store.loadRecentHistoryChunk(
                        threadID: sessionID,
                        timelineLimit: timelineLimit,
                        transcriptLimit: transcriptLimit
                    ))
                }
            }
        }
        return await sessionCatalog.loadRecentHistoryChunk(
            sessionID: sessionID,
            timelineLimit: timelineLimit,
            transcriptLimit: transcriptLimit
        )
    }

    private func conversationPersistenceKind(for sessionID: String?) -> AssistantConversationPersistenceKind {
        guard let normalizedSessionID = normalizedSessionID(sessionID),
              let session = sessions.first(where: { sessionsMatch($0.id, normalizedSessionID) }) else {
            return .snapshotOnly
        }
        return session.conversationPersistence
    }

    private func conversationPersistsHistory(for sessionID: String?) -> Bool {
        guard let normalizedSessionID = normalizedSessionID(sessionID),
              let session = sessions.first(where: { sessionsMatch($0.id, normalizedSessionID) }) else {
            return false
        }
        return session.persistsConversationHistory
    }

    private func shouldUseHybridConversationPersistence(sessionID: String?) -> Bool {
        guard let normalizedSessionID = normalizedSessionID(sessionID) else { return false }
        return isProviderIndependentThreadV2(sessionID: normalizedSessionID)
            && conversationPersistenceKind(for: normalizedSessionID) == .hybridJSONL
    }

    private func cancelPendingConversationSnapshotSave(sessionID: String) {
        pendingConversationSnapshotSaveWorkItems[sessionID]?.cancel()
        pendingConversationSnapshotSaveWorkItems[sessionID] = nil
    }

    private func saveConversationSnapshotNow(sessionID: String) throws {
        let normalizedSessionID = normalizedSessionID(sessionID) ?? sessionID
        guard isProviderIndependentThreadV2(sessionID: normalizedSessionID),
              conversationPersistsHistory(for: normalizedSessionID) else { return }

        let timeline = timelineItemsBySessionID[normalizedSessionID]
            ?? (sessionsMatch(timelineSessionID, normalizedSessionID) ? timelineItems : [])
        let transcript = transcriptEntriesBySessionID[normalizedSessionID]
            ?? (sessionsMatch(transcriptSessionID, normalizedSessionID) ? self.transcript : [])
        let session = sessions.first(where: { sessionsMatch($0.id, normalizedSessionID) })

        try conversationStore.saveSnapshot(
            threadID: normalizedSessionID,
            timeline: timeline,
            transcript: transcript,
            session: session,
            persistenceKind: conversationPersistenceKind(for: normalizedSessionID)
        )

        dirtyConversationSnapshotSessionIDs.remove(normalizedSessionID)
        cancelPendingConversationSnapshotSave(sessionID: normalizedSessionID)
    }

    private func recordConversationMutationIfNeeded(
        sessionID: String?,
        forceSnapshotFlush: Bool = false,
        eventAppender: (_ normalizedSessionID: String) throws -> Void
    ) {
        guard let normalizedSessionID = normalizedSessionID(sessionID),
              conversationPersistsHistory(for: normalizedSessionID),
              Self.shouldPersistConversationMutation(
                normalizedSessionID: normalizedSessionID,
                isProviderIndependentThreadV2: isProviderIndependentThreadV2(sessionID: normalizedSessionID),
                deletedSessionIDs: deletedSessionIDs
              ) else {
            return
        }

        if shouldUseHybridConversationPersistence(sessionID: normalizedSessionID) {
            do {
                try eventAppender(normalizedSessionID)
                dirtyConversationSnapshotSessionIDs.insert(normalizedSessionID)
                persistConversationSnapshotIfNeeded(
                    sessionID: normalizedSessionID,
                    force: forceSnapshotFlush
                )
            } catch {
                try? saveConversationSnapshotNow(sessionID: normalizedSessionID)
            }
            return
        }

        try? saveConversationSnapshotNow(sessionID: normalizedSessionID)
    }

    static func shouldPersistConversationMutation(
        normalizedSessionID: String?,
        isProviderIndependentThreadV2: Bool,
        deletedSessionIDs: Set<String>
    ) -> Bool {
        guard let normalizedSessionID = normalizedSessionID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty?
            .lowercased(),
              isProviderIndependentThreadV2 else {
            return false
        }

        return !deletedSessionIDs.contains(normalizedSessionID)
    }

    private func flushPersistedHistoryIfNeeded(sessionID: String?) {
        guard let normalizedSessionID = normalizedSessionID(sessionID) else { return }
        guard conversationPersistsHistory(for: normalizedSessionID) else { return }
        if isProviderIndependentThreadV2(sessionID: normalizedSessionID) {
            persistConversationSnapshotIfNeeded(sessionID: normalizedSessionID, force: true)
        } else {
            persistTimelineCacheIfNeeded(sessionID: normalizedSessionID, force: true)
        }
    }

    private func persistConversationSnapshotIfNeeded(sessionID: String?, force: Bool = false) {
        guard let normalizedSessionID = normalizedSessionID(sessionID),
              isProviderIndependentThreadV2(sessionID: normalizedSessionID),
              conversationPersistsHistory(for: normalizedSessionID) else {
            return
        }

        if shouldUseHybridConversationPersistence(sessionID: normalizedSessionID) {
            if !force && !dirtyConversationSnapshotSessionIDs.contains(normalizedSessionID) {
                return
            }

            if force {
                cancelPendingConversationSnapshotSave(sessionID: normalizedSessionID)
                try? saveConversationSnapshotNow(sessionID: normalizedSessionID)
                return
            }

            cancelPendingConversationSnapshotSave(sessionID: normalizedSessionID)
            let workItem = DispatchWorkItem { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    try? self.saveConversationSnapshotNow(sessionID: normalizedSessionID)
                }
            }
            pendingConversationSnapshotSaveWorkItems[normalizedSessionID] = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.timelineCacheSaveDebounceInterval,
                execute: workItem
            )
            return
        }

        try? saveConversationSnapshotNow(sessionID: normalizedSessionID)
    }

    private func backend(for session: AssistantSessionSummary) -> AssistantRuntimeBackend {
        if let providerBackend = session.activeProviderBackend {
            return providerBackend
        }
        return assistantBackend
    }

    private func providerSessionID(
        for session: AssistantSessionSummary?,
        backend: AssistantRuntimeBackend? = nil
    ) -> String? {
        guard let session else { return nil }

        if let backend {
            if backend == .ollamaLocal {
                return session.id
            }
            if session.isCanonicalThread {
                return session.providerBinding(for: backend)?
                    .providerSessionID?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty
            }
            return self.backend(for: session) == backend ? session.id : nil
        }

        if self.backend(for: session) == .ollamaLocal {
            return session.id
        }
        if let providerSessionID = session.activeProviderSessionID {
            return providerSessionID
        }
        return session.isCanonicalThread ? nil : session.id
    }

    private func runtimeResumeSessionID(forThreadID threadID: String) -> String {
        guard let session = sessions.first(where: { sessionsMatch($0.id, threadID) }) else {
            return threadID
        }
        return providerSessionID(for: session) ?? threadID
    }

    private func preferredModelID(
        for session: AssistantSessionSummary,
        backend: AssistantRuntimeBackend
    ) -> String? {
        if session.isProviderIndependentThreadV2 {
            return session.providerBinding(for: backend)?
                .latestModelID?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty
                ?? settings.assistantPreferredModelID.nonEmpty
                ?? selectedModelID
        }

        return session.latestModel?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? settings.assistantPreferredModelID.nonEmpty
            ?? selectedModelID
    }

    private func silentlyResumeStoredProviderSession(
        using runtime: CodexAssistantRuntime,
        session: AssistantSessionSummary,
        backend: AssistantRuntimeBackend,
        suppressErrors: Bool
    ) async -> Bool {
        guard let storedProviderSessionID = providerSessionID(for: session, backend: backend) else {
            return false
        }

        do {
            await ensureRuntimeBackend(runtime, matches: backend)
            try await runtime.resumeSessionSilently(
                storedProviderSessionID,
                cwd: resolvedSessionCWD(for: session.id),
                preferredModelID: preferredModelID(for: session, backend: backend)
            )
            if session.isCanonicalThread {
                updateProviderLink(
                    forThreadID: session.id,
                    backend: backend,
                    providerSessionID: runtime.currentSessionID ?? storedProviderSessionID
                )
            }
            return true
        } catch {
            if !suppressErrors,
               await recoverStoredProviderSessionIfNeeded(
                after: error,
                threadID: session.id,
                backend: backend
               ) {
                return true
            }
            if !suppressErrors {
                lastStatusMessage = error.localizedDescription
            }
            return false
        }
    }

    private func updateProviderLink(
        forThreadID threadID: String,
        backend: AssistantRuntimeBackend,
        providerSessionID: String?
    ) {
        guard let sessionIndex = sessions.firstIndex(where: { sessionsMatch($0.id, threadID) }) else {
            return
        }
        var session = sessions[sessionIndex]
        guard session.isCanonicalThread else { return }

        let normalizedProviderSessionID = providerSessionID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
        if session.isProviderIndependentThreadV2 {
            var binding = session.providerBinding(for: backend)
                ?? AssistantProviderBinding(backend: backend)
            let needsUpdate = session.activeProvider != backend
                || !sessionsMatch(binding.providerSessionID, normalizedProviderSessionID)
            guard needsUpdate else { return }

            binding.providerSessionID = normalizedProviderSessionID
            binding.latestModelID = selectedModelID ?? binding.latestModelID
            binding.latestInteractionMode = interactionMode
            binding.latestReasoningEffort = reasoningEffort
            binding.latestServiceTier = fastModeEnabled ? "fast" : nil
            binding.lastConnectedAt = Date()
            session.setProviderBinding(binding)
            session.activeProvider = backend
        } else {
            let needsUpdate = session.providerBackend != backend
                || !sessionsMatch(session.providerSessionID, normalizedProviderSessionID)
            guard needsUpdate else { return }

            session.providerBackend = backend
            session.providerSessionID = normalizedProviderSessionID
        }
        sessions[sessionIndex] = session
        persistManagedSessionsSnapshot()
    }

    private func ensureRuntimeBackend(
        _ runtime: CodexAssistantRuntime,
        matches backend: AssistantRuntimeBackend
    ) async {
        guard runtime.backend != backend else { return }
        await runtime.stop()
        runtime.clearCachedEnvironmentState()
        runtime.backend = backend
    }

    private func sessionMatchesIdentity(
        _ session: AssistantSessionSummary,
        sessionID: String,
        source: AssistantSessionSource? = nil
    ) -> Bool {
        guard sessionsMatch(session.id, sessionID) else { return false }
        guard let source else { return true }
        return session.source == source
    }

    private func deduplicateSessions(_ sessions: [AssistantSessionSummary]) -> [AssistantSessionSummary] {
        var ordered: [AssistantSessionSummary] = []
        var seen = Set<String>()

        for session in sessions {
            let key = [
                session.source.rawValue.lowercased(),
                normalizedSessionID(session.id) ?? session.id.lowercased()
            ].joined(separator: "::")
            guard seen.insert(key).inserted else { continue }
            ordered.append(session)
        }

        return ordered
    }

    private func sortSessionsByRecency(_ sessions: [AssistantSessionSummary]) -> [AssistantSessionSummary] {
        sessions.sorted {
            let lhsDate = $0.updatedAt ?? $0.createdAt ?? .distantPast
            let rhsDate = $1.updatedAt ?? $1.createdAt ?? .distantPast
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
            if $0.title != $1.title {
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            if $0.source != $1.source {
                return $0.source.rawValue < $1.source.rawValue
            }
            return $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending
        }
    }

    private func reconcilePendingFreshSessions(with loadedSessionIDs: Set<String>) {
        pendingFreshSessionIDs = pendingFreshSessionIDs.intersection(loadedSessionIDs)
        pendingFreshSessionSourcesByID = pendingFreshSessionSourcesByID.filter { key, _ in
            loadedSessionIDs.contains(key)
        }
    }

    private func isPendingFreshSession(_ sessionID: String?) -> Bool {
        Self.shouldSkipPendingFreshSessionResume(
            sessionID,
            pendingSessionIDs: pendingFreshSessionIDs
        )
    }

    private func markPendingFreshSession(
        _ sessionID: String?,
        source: AssistantSessionSource? = nil
    ) {
        guard let normalizedSessionID = normalizedSessionID(sessionID) else {
            return
        }
        pendingFreshSessionIDs.insert(normalizedSessionID)
        if let source {
            pendingFreshSessionSourcesByID[normalizedSessionID] = source
        }
    }

    private func clearPendingFreshSession(_ sessionID: String?) {
        guard let normalizedSessionID = normalizedSessionID(sessionID) else {
            return
        }
        pendingFreshSessionIDs.remove(normalizedSessionID)
        pendingFreshSessionSourcesByID.removeValue(forKey: normalizedSessionID)
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
                    source: pendingFreshSessionSourcesByID[normalizedSessionID]
                        ?? assistantBackend.sessionSource,
                    status: Self.normalizedFreshSessionStatus(
                        currentStatus: .active,
                        hasConversationContent: false,
                        hasActiveTurn: runtime.hasActiveTurn
                    ),
                    cwd: resolvedSessionCWD(for: sessionID),
                    createdAt: Date(),
                    updatedAt: Date(),
                    summary: nil,
                    latestModel: selectedModelID,
                    latestTaskMode: taskMode,
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
            if isProviderIndependentThreadV2(sessionID: sessionID) {
                persistConversationSnapshotIfNeeded(sessionID: sessionID)
            } else {
                sessionCatalog.saveNormalizedTimeline(itemsToSave, for: sessionID)
            }
            return
        }

        pendingTimelineCacheSaveWorkItems[sessionID]?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.isProviderIndependentThreadV2(sessionID: sessionID) {
                    self.persistConversationSnapshotIfNeeded(sessionID: sessionID)
                } else {
                    self.sessionCatalog.saveNormalizedTimeline(itemsToSave, for: sessionID)
                }
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

    private struct ProviderRecoveryImageDerivedAnswer: Equatable {
        let userText: String?
        let assistantText: String
    }

    private static func buildProviderRecoveryPromptTurns(
        from transcriptEntries: [AssistantTranscriptEntry],
        maxMeaningfulEntries: Int
    ) -> [PromptRewriteConversationTurn] {
        let meaningfulEntries = transcriptEntries
            .filter { entry in
                guard !entry.isStreaming else { return false }
                switch entry.role {
                case .user, .assistant, .error:
                    return entry.text.nonEmpty != nil
                case .system, .status, .tool, .permission:
                    return false
                }
            }
            .suffix(maxMeaningfulEntries)

        var output: [PromptRewriteConversationTurn] = []
        var pendingUserText: String?
        var pendingTimestamp: Date?
        var assistantParts: [String] = []

        func flushTurn() {
            guard pendingUserText != nil || !assistantParts.isEmpty else { return }
            output.append(
                PromptRewriteConversationTurn(
                    userText: pendingUserText ?? "",
                    assistantText: assistantParts.joined(separator: "\n"),
                    timestamp: pendingTimestamp ?? Date()
                )
            )
            pendingUserText = nil
            pendingTimestamp = nil
            assistantParts = []
        }

        for entry in meaningfulEntries {
            let normalizedText = normalizedResumeContextSnippet(entry.text, limit: 480)
            guard !normalizedText.isEmpty else { continue }

            switch entry.role {
            case .user:
                flushTurn()
                pendingUserText = normalizedText
                pendingTimestamp = entry.createdAt
            case .assistant:
                assistantParts.append(normalizedText)
                pendingTimestamp = entry.createdAt
            case .error:
                assistantParts.append("Error: \(normalizedText)")
                pendingTimestamp = entry.createdAt
            case .system, .status, .tool, .permission:
                break
            }
        }

        flushTurn()
        return output
    }

    private static func latestImageDerivedAnswer(
        in timelineItems: [AssistantTimelineItem]
    ) -> ProviderRecoveryImageDerivedAnswer? {
        let sortedItems = timelineItems.sorted {
            if $0.sortDate == $1.sortDate {
                return $0.id < $1.id
            }
            return $0.sortDate < $1.sortDate
        }

        for item in sortedItems.reversed() {
            guard item.kind == .assistantFinal,
                  let assistantText = item.text?.nonEmpty,
                  recoveryTimelineTurnHasImages(item, in: sortedItems) else {
                continue
            }

            let userText = latestUserTextForTimelineTurn(item.turnID, in: sortedItems)
            return ProviderRecoveryImageDerivedAnswer(
                userText: userText,
                assistantText: normalizedResumeContextSnippet(assistantText, limit: 1_200)
            )
        }

        return nil
    }

    private static func recoveryTimelineTurnHasImages(
        _ item: AssistantTimelineItem,
        in items: [AssistantTimelineItem]
    ) -> Bool {
        if item.imageAttachments?.isEmpty == false {
            return true
        }

        guard let turnID = item.turnID?.nonEmpty else { return false }
        return items.contains { candidate in
            candidate.turnID?.nonEmpty == turnID && (candidate.imageAttachments?.isEmpty == false)
        }
    }

    private static func latestUserTextForTimelineTurn(
        _ turnID: String?,
        in items: [AssistantTimelineItem]
    ) -> String? {
        guard let turnID = turnID?.nonEmpty else { return nil }
        return items.reversed().first(where: { item in
            item.turnID?.nonEmpty == turnID
                && item.kind == .userMessage
                && item.text?.nonEmpty != nil
        })?.text.flatMap { normalizedResumeContextSnippet($0, limit: 420).nonEmpty }
    }

    private static func latestMeaningfulRecoveryUserText(
        in turns: [PromptRewriteConversationTurn],
        fallback: String?
    ) -> String? {
        if let recentUser = turns.reversed().compactMap({ $0.userText.nonEmpty }).first {
            return normalizedResumeContextSnippet(recentUser, limit: 320)
        }
        guard let fallback = fallback?.nonEmpty else { return nil }
        return normalizedResumeContextSnippet(fallback, limit: 320)
    }

    private static func providerRecoveryConversationContext(
        for sessionSummary: AssistantSessionSummary?
    ) -> PromptRewriteConversationContext {
        let appName = ((Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)?.nonEmpty)
            ?? "Open Assist"
        let bundleIdentifier = Bundle.main.bundleIdentifier?.nonEmpty ?? "com.openassist.app"
        return PromptRewriteConversationContext(
            id: sessionSummary?.id.nonEmpty ?? UUID().uuidString,
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            screenLabel: "Assistant Thread Recovery",
            fieldLabel: sessionSummary?.title.nonEmpty ?? "Chat Composer",
            logicalSurfaceKey: "assistant-thread-recovery",
            projectKey: sessionSummary?.projectID?.lowercased(),
            projectLabel: sessionSummary?.projectName?.nonEmpty,
            nativeThreadKey: sessionSummary?.id.nonEmpty,
            people: []
        )
    }

    private static func providerRecoverySummarySeed(
        sections: [String],
        limit: Int
    ) -> String {
        let joined = sections
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return normalizedProviderRecoverySummaryText(joined, limit: limit)
    }

    private static func normalizedProviderRecoverySummaryText(
        _ text: String,
        limit: Int
    ) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "" }
        guard normalized.count > limit else { return normalized }

        let cutoffIndex = normalized.index(
            normalized.startIndex,
            offsetBy: max(0, limit - 3)
        )
        let prefix = String(normalized[..<cutoffIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix.isEmpty ? "" : prefix + "..."
    }
}

private enum AssistantPromptRoutingError: LocalizedError {
    case activeTurnInDifferentSession
    case liveSessionLimitReached(limit: Int)

    var errorDescription: String? {
        switch self {
        case .activeTurnInDifferentSession:
            return "Another session is still running. Let it finish before sending a message to this session."
        case .liveSessionLimitReached(let limit):
            return "You already have \(limit) chats running or waiting for approval. Finish one or stop one before starting another."
        }
    }
}

extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var streamingDeltaPreservingWhitespace: String? {
        isEmpty ? nil : self
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

extension AssistantSessionSummary {
    var hasConversationContent: Bool {
        summary?.assistantNonEmpty != nil
            || latestUserMessage?.assistantNonEmpty != nil
            || latestAssistantMessage?.assistantNonEmpty != nil
    }
}
