import AppKit
import SwiftUI
import UniformTypeIdentifiers

let assistantComposerTextHorizontalInset: CGFloat = 12
let assistantComposerTextVerticalInset: CGFloat = 7
let assistantComposerLineFragmentPadding: CGFloat = 4
let assistantComposerMinTextHeight: CGFloat = 44
let assistantComposerMaxTextHeight: CGFloat = 88

@MainActor
enum AssistantWindowChrome {
    private static var isDarkAppearance: Bool { AppVisualTheme.isDarkAppearance }

    static var canvasTop: Color {
        isDarkAppearance ? Color(red: 0.050, green: 0.052, blue: 0.062) : AppVisualTheme.windowBackground
    }

    static var canvasBottom: Color {
        isDarkAppearance ? Color(red: 0.028, green: 0.030, blue: 0.038) : Color(nsColor: .underPageBackgroundColor)
    }

    static var shellTop: Color {
        isDarkAppearance ? Color(red: 0.078, green: 0.082, blue: 0.098) : AppVisualTheme.surfaceFill(0.86)
    }

    static var shellBottom: Color {
        isDarkAppearance ? Color(red: 0.060, green: 0.064, blue: 0.078) : AppVisualTheme.surfaceFill(0.74)
    }

    static var sidebarTop: Color {
        isDarkAppearance ? Color(red: 0.068, green: 0.072, blue: 0.086) : AppVisualTheme.surfaceFill(0.92)
    }

    static var sidebarBottom: Color {
        isDarkAppearance ? Color(red: 0.050, green: 0.054, blue: 0.066) : AppVisualTheme.surfaceFill(0.80)
    }

    static var contentTop: Color {
        isDarkAppearance ? Color(red: 0.082, green: 0.086, blue: 0.102) : AppVisualTheme.textBackground
    }

    static var contentBottom: Color {
        isDarkAppearance ? Color(red: 0.065, green: 0.068, blue: 0.082) : AppVisualTheme.controlBackground
    }

    static var elevatedPanel: Color {
        isDarkAppearance ? Color(red: 0.092, green: 0.096, blue: 0.114) : AppVisualTheme.surfaceFill(0.94)
    }

    static var messagePanel: Color {
        isDarkAppearance ? Color(red: 0.088, green: 0.092, blue: 0.108) : AppVisualTheme.surfaceFill(0.88)
    }

    static var userBubble: Color {
        isDarkAppearance ? Color(red: 0.110, green: 0.116, blue: 0.138) : AppVisualTheme.selectedContentBackground.opacity(0.88)
    }

    static var userBubbleBorder: Color {
        isDarkAppearance ? Color(red: 0.260, green: 0.340, blue: 0.480).opacity(0.50) : AppVisualTheme.surfaceStroke(0.55)
    }

    static var editorFill: Color {
        isDarkAppearance ? Color(red: 0.065, green: 0.068, blue: 0.082) : AppVisualTheme.textBackground
    }

    static var toolbarFill: Color {
        isDarkAppearance ? Color(red: 0.072, green: 0.076, blue: 0.092) : AppVisualTheme.surfaceFill(0.86)
    }

    static var buttonFill: Color {
        isDarkAppearance ? Color.white.opacity(0.050) : AppVisualTheme.surfaceFill(0.56)
    }

    static var buttonEmphasis: Color {
        isDarkAppearance ? Color(red: 0.130, green: 0.148, blue: 0.195) : AppVisualTheme.accentTint.opacity(0.16)
    }

    static var border: Color { AppVisualTheme.surfaceStroke(0.58) }
    static var strongBorder: Color { AppVisualTheme.surfaceStroke(0.82) }
    static var neutralAccent: Color { Color(red: 0.46, green: 0.58, blue: 0.74) }
    static var systemTint: Color { Color(red: 0.52, green: 0.64, blue: 0.78) }
    static var sidebarDivider: Color { AppVisualTheme.surfaceStroke(0.40) }
    static var sectionHeader: Color { AppVisualTheme.secondaryText }
}

enum TimelineDisclosureState {
    case collapsed
    case expanded
}

struct TimelineActivityDetailSectionData {
    let title: String
    let text: String
}

@MainActor
final class AssistantChatScrollTracking {
    var lastManualScrollAt: Date = .distantPast
}

func assistantFormattedActivityDetailText(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return text }
    return assistantPrettyPrintedActivityDetailJSON(trimmed) ?? trimmed
}

func assistantPrettyPrintedActivityDetailJSON(
    _ text: String,
    nestingDepth: Int = 0
) -> String? {
    guard nestingDepth < 3,
          let data = text.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) else {
        return nil
    }

    if let nestedJSONString = object as? String {
        let nestedTrimmed = nestedJSONString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nestedTrimmed.isEmpty else { return nestedJSONString }
        return assistantPrettyPrintedActivityDetailJSON(
            nestedTrimmed,
            nestingDepth: nestingDepth + 1
        ) ?? nestedTrimmed
    }

    guard JSONSerialization.isValidJSONObject(object),
          let prettyData = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
          ),
          let prettyText = String(data: prettyData, encoding: .utf8) else {
        return nil
    }

    return prettyText
}

func assistantLooksLikeUnifiedDiff(_ text: String?) -> Bool {
    guard let trimmed = text?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .assistantNonEmpty else {
        return false
    }

    if trimmed.hasPrefix("```diff") {
        return true
    }

    if trimmed.hasPrefix("diff --git ") {
        return true
    }

    let normalized = trimmed.replacingOccurrences(of: "\r\n", with: "\n")
    return (normalized.contains("\n--- ") && normalized.contains("\n+++ "))
        || normalized.contains("\n@@ ")
        || normalized.contains("\n@@ -")
}


struct AssistantTimelineActivityGroup: Identifiable, Equatable {
    let items: [AssistantTimelineItem]

    var id: String {
        let firstID = items.first?.id ?? UUID().uuidString
        let lastID = items.last?.id ?? firstID
        return "activity-group-\(firstID)-\(lastID)"
    }

    var activities: [AssistantActivityItem] {
        items.compactMap(\.activity)
    }

    var sortDate: Date {
        items.first?.sortDate ?? .distantPast
    }

    var lastUpdatedAt: Date {
        items.map(\.lastUpdatedAt).max() ?? sortDate
    }
}

enum AssistantTimelineRenderItem: Identifiable, Equatable {
    case timeline(AssistantTimelineItem)
    case activityGroup(AssistantTimelineActivityGroup)

    var id: String {
        switch self {
        case .timeline(let item):
            return item.id
        case .activityGroup(let group):
            return group.id
        }
    }

    var lastUpdatedAt: Date {
        switch self {
        case .timeline(let item):
            return item.lastUpdatedAt
        case .activityGroup(let group):
            return group.lastUpdatedAt
        }
    }
}

func buildAssistantTimelineRenderItems(from items: [AssistantTimelineItem]) -> [AssistantTimelineRenderItem] {
    var renderItems: [AssistantTimelineRenderItem] = []
    var activityBuffer: [AssistantTimelineItem] = []

    func flushActivityBuffer() {
        guard !activityBuffer.isEmpty else { return }
        if activityBuffer.count == 1, let single = activityBuffer.first {
            renderItems.append(.timeline(single))
        } else {
            renderItems.append(.activityGroup(AssistantTimelineActivityGroup(items: activityBuffer)))
        }
        activityBuffer.removeAll(keepingCapacity: true)
    }

    for item in items {
        if item.kind == .activity, item.activity != nil {
            activityBuffer.append(item)
        } else {
            flushActivityBuffer()
            renderItems.append(.timeline(item))
        }
    }

    flushActivityBuffer()
    return renderItems
}

func assistantTimelineVisibleWindow(
    from items: [AssistantTimelineRenderItem],
    visibleLimit: Int
) -> [AssistantTimelineRenderItem] {
    guard !items.isEmpty else { return [] }

    let normalizedLimit = max(1, visibleLimit)
    guard items.count > normalizedLimit else { return items }
    return Array(items.suffix(normalizedLimit))
}

func assistantTimelineNextVisibleLimit(
    currentLimit: Int,
    totalCount: Int,
    batchSize: Int
) -> Int {
    guard totalCount > 0 else { return 0 }

    let normalizedCurrent = max(0, currentLimit)
    let normalizedBatch = max(1, batchSize)
    return min(totalCount, max(1, normalizedCurrent + normalizedBatch))
}

func assistantTimelineSessionIDsMatch(_ lhs: String?, _ rhs: String?) -> Bool {
    guard let lhs = lhs?.trimmingCharacters(in: .whitespacesAndNewlines),
          let rhs = rhs?.trimmingCharacters(in: .whitespacesAndNewlines),
          !lhs.isEmpty,
          !rhs.isEmpty else {
        return false
    }

    return lhs.caseInsensitiveCompare(rhs) == .orderedSame
}

struct AssistantSessionToolActivitySnapshot: Equatable {
    let activeCalls: [AssistantToolCallState]
    let recentCalls: [AssistantToolCallState]

    var hasActivity: Bool {
        !activeCalls.isEmpty || !recentCalls.isEmpty
    }

    static let empty = AssistantSessionToolActivitySnapshot(
        activeCalls: [],
        recentCalls: []
    )
}

struct AssistantSessionActiveWorkSnapshot: Equatable {
    let sessionID: String
    let planEntries: [AssistantPlanEntry]
    let subagents: [SubagentState]
    let fileChangeCount: Int

    var completedTaskCount: Int {
        planEntries.filter { assistantPlanEntryIsCompleted($0.status) }.count
    }

    var totalTaskCount: Int {
        planEntries.count
    }

    var hasChecklist: Bool {
        !planEntries.isEmpty
    }

    var hasFileChanges: Bool {
        fileChangeCount > 0
    }

    var hasBackgroundAgents: Bool {
        !subagents.isEmpty
    }
}

struct AssistantParentThreadLinkState: Equatable {
    let parentThreadID: String
    let childAgent: SubagentState
}

func assistantSessionOwnsLiveRuntimeState(
    sessionID: String?,
    activeRuntimeSessionID: String?
) -> Bool {
    assistantTimelineSessionIDsMatch(sessionID, activeRuntimeSessionID)
}

func assistantShouldShowPendingAssistantPlaceholder(
    selectedSessionID: String?,
    activeRuntimeSessionID: String?,
    hasPendingPermissionRequest: Bool,
    hasVisibleStreamingAssistantMessage: Bool,
    hudPhase: AssistantHUDPhase
) -> Bool {
    guard selectedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
        return false
    }
    guard assistantSessionOwnsLiveRuntimeState(
        sessionID: selectedSessionID,
        activeRuntimeSessionID: activeRuntimeSessionID
    ) else {
        return false
    }
    guard !hasPendingPermissionRequest else { return false }
    guard !hasVisibleStreamingAssistantMessage else { return false }

    switch hudPhase {
    case .thinking, .acting, .streaming:
        return true
    default:
        return false
    }
}

func assistantSelectedSessionToolActivity(
    selectedSessionID: String?,
    activeRuntimeSessionID: String?,
    hasActiveTurn: Bool,
    toolCalls: [AssistantToolCallState],
    recentToolCalls: [AssistantToolCallState]
) -> AssistantSessionToolActivitySnapshot {
    guard assistantSessionOwnsLiveRuntimeState(
        sessionID: selectedSessionID,
        activeRuntimeSessionID: activeRuntimeSessionID
    ) else {
        return .empty
    }

    guard hasActiveTurn else {
        let archivedActiveCalls = toolCalls.map { call -> AssistantToolCallState in
            var archived = call
            let normalizedStatus = archived.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["inprogress", "running", "working", "active", "started", "pending"].contains(normalizedStatus) {
                archived.status = "completed"
            }
            return archived
        }

        return AssistantSessionToolActivitySnapshot(
            activeCalls: [],
            recentCalls: archivedActiveCalls + recentToolCalls
        )
    }

    return AssistantSessionToolActivitySnapshot(
        activeCalls: toolCalls,
        recentCalls: recentToolCalls
    )
}

func assistantSelectedSessionActiveWorkSnapshot(
    selectedSessionID: String?,
    activeRuntimeSessionID _: String?,
    planEntries: [AssistantPlanEntry],
    subagents: [SubagentState],
    toolCalls: [AssistantToolCallState],
    recentToolCalls: [AssistantToolCallState]
) -> AssistantSessionActiveWorkSnapshot? {
    guard let selectedSessionID = selectedSessionID?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .nonEmpty else {
        return nil
    }

    let childAgents = subagents.filter { agent in
        assistantTimelineSessionIDsMatch(agent.parentThreadID, selectedSessionID)
    }
    guard !childAgents.isEmpty else { return nil }

    return AssistantSessionActiveWorkSnapshot(
        sessionID: selectedSessionID,
        planEntries: planEntries,
        subagents: childAgents,
        fileChangeCount: assistantFileChangeCount(in: toolCalls + recentToolCalls)
    )
}

func assistantSidebarChildSubagents(
    parentSessionID: String,
    selectedSessionID _: String?,
    activeRuntimeSessionID _: String?,
    subagents: [SubagentState]
) -> [SubagentState] {
    return subagents.filter { agent in
        assistantTimelineSessionIDsMatch(agent.parentThreadID, parentSessionID)
    }
}

func assistantParentThreadLinkState(
    selectedSessionID: String?,
    activeRuntimeSessionID _: String?,
    subagents: [SubagentState]
) -> AssistantParentThreadLinkState? {
    guard let selectedSessionID = selectedSessionID?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .nonEmpty else {
        return nil
    }

    guard let childAgent = subagents.first(where: {
        assistantTimelineSessionIDsMatch($0.threadID, selectedSessionID)
            && $0.parentThreadID?.nonEmpty != nil
    }),
    let parentThreadID = childAgent.parentThreadID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
        return nil
    }

    return AssistantParentThreadLinkState(
        parentThreadID: parentThreadID,
        childAgent: childAgent
    )
}

private func assistantPlanEntryIsCompleted(_ status: String) -> Bool {
    let normalizedStatus = status
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "-", with: "_")
        .lowercased()
    return normalizedStatus == "completed"
}

private func assistantFileChangeCount(in calls: [AssistantToolCallState]) -> Int {
    calls.reduce(into: 0) { total, call in
        guard call.kind == "fileChange" else { return }

        if let detail = call.detail?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
           let parsedCount = assistantLeadingInteger(in: detail) {
            total += parsedCount
        } else {
            total += 1
        }
    }
}

private func assistantLeadingInteger(in text: String) -> Int? {
    let digits = text.prefix { $0.isNumber }
    guard !digits.isEmpty else { return nil }
    return Int(digits)
}

func assistantSidebarActivityState(
    forSessionID sessionID: String,
    selectedSessionID: String?,
    activeRuntimeSessionID: String?,
    sessionStatus: AssistantSessionStatus,
    hasPendingPermissionRequest: Bool,
    hudPhase: AssistantHUDPhase,
    isTransitioningSession: Bool,
    isLiveVoiceSessionActive: Bool,
    hasActiveTurn: Bool
) -> AssistantSessionRow.ActivityState {
    let isSelectedSession = assistantTimelineSessionIDsMatch(selectedSessionID, sessionID)
    let ownsLiveRuntimeState = assistantSessionOwnsLiveRuntimeState(
        sessionID: sessionID,
        activeRuntimeSessionID: activeRuntimeSessionID
    )

    if ownsLiveRuntimeState {
        if hasPendingPermissionRequest || hudPhase == .waitingForPermission {
            return .waiting
        }
        if isTransitioningSession || hudPhase.isActive || isLiveVoiceSessionActive {
            return .running
        }
        if hudPhase == .failed {
            return .failed
        }
    }

    if isSelectedSession {
        switch sessionStatus {
        case .active:
            // Fresh sessions can stay marked active for a moment after the turn ends.
            // Keep the selected thread calm unless it is the one that actually owns
            // the current runtime work.
            return ownsLiveRuntimeState && hasActiveTurn ? .running : .idle
        case .waitingForApproval, .waitingForInput:
            return .waiting
        case .failed:
            return .failed
        case .unknown, .idle, .completed:
            return .idle
        }
    }

    switch sessionStatus {
    case .active:
        return .running
    case .waitingForApproval, .waitingForInput:
        return .waiting
    case .failed:
        return .failed
    case .unknown, .idle, .completed:
        return .idle
    }
}
