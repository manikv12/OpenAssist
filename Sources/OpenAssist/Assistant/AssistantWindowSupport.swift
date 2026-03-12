import AppKit
import MarkdownUI
import SwiftUI
import UniformTypeIdentifiers

let assistantComposerTextHorizontalInset: CGFloat = 12
let assistantComposerTextVerticalInset: CGFloat = 7
let assistantComposerLineFragmentPadding: CGFloat = 4
let assistantComposerMinTextHeight: CGFloat = 44
let assistantComposerMaxTextHeight: CGFloat = 88

enum AssistantWindowChrome {
    static let canvasTop = Color(red: 0.055, green: 0.060, blue: 0.072)
    static let canvasBottom = Color(red: 0.032, green: 0.035, blue: 0.043)
    static let shellTop = Color(red: 0.090, green: 0.096, blue: 0.112)
    static let shellBottom = Color(red: 0.072, green: 0.077, blue: 0.092)
    static let sidebarTop = Color(red: 0.082, green: 0.087, blue: 0.101)
    static let sidebarBottom = Color(red: 0.064, green: 0.068, blue: 0.080)
    static let contentTop = Color(red: 0.098, green: 0.104, blue: 0.120)
    static let contentBottom = Color(red: 0.078, green: 0.083, blue: 0.098)
    static let elevatedPanel = Color(red: 0.108, green: 0.114, blue: 0.131)
    static let messagePanel = Color(red: 0.112, green: 0.118, blue: 0.136)
    static let userBubble = Color(red: 0.122, green: 0.128, blue: 0.146)
    static let userBubbleBorder = Color(red: 0.285, green: 0.365, blue: 0.485).opacity(0.60)
    static let editorFill = Color(red: 0.080, green: 0.085, blue: 0.099)
    static let toolbarFill = Color(red: 0.102, green: 0.108, blue: 0.124)
    static let buttonFill = Color.white.opacity(0.055)
    static let buttonEmphasis = Color(red: 0.145, green: 0.165, blue: 0.208)
    static let border = Color.white.opacity(0.08)
    static let strongBorder = Color.white.opacity(0.13)
    static let neutralAccent = Color(red: 0.46, green: 0.58, blue: 0.74)
    static let systemTint = Color(red: 0.52, green: 0.64, blue: 0.78)
}

enum TimelineDisclosureState {
    case collapsed
    case expanded
}

struct TimelineActivityDetailSectionData {
    let title: String
    let text: String
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

