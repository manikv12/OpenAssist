import Foundation
import UniformTypeIdentifiers

enum AssistantTimelineSource: String, Codable, Sendable {
    case runtime
    case codexSession
    case cache
}

enum AssistantActivityKind: String, Codable, Sendable {
    case commandExecution
    case fileChange
    case webSearch
    case browserAutomation
    case mcpToolCall
    case dynamicToolCall
    case subagent
    case reasoning
    case other
}

enum AssistantActivityStatus: String, Codable, Sendable {
    case pending
    case running
    case waiting
    case completed
    case failed
    case interrupted

    var isActive: Bool {
        switch self {
        case .pending, .running, .waiting:
            return true
        case .completed, .failed, .interrupted:
            return false
        }
    }
}

struct AssistantActivityItem: Identifiable, Equatable, Codable, Sendable {
    let id: String
    var sessionID: String?
    var turnID: String?
    var kind: AssistantActivityKind
    var title: String
    var status: AssistantActivityStatus
    var friendlySummary: String
    var rawDetails: String?
    var startedAt: Date
    var updatedAt: Date
    var source: AssistantTimelineSource

    var isActive: Bool { status.isActive }
}

enum AssistantActivityOpenTargetKind: String, Equatable, Sendable {
    case file
    case webSearch
    case url
}

struct AssistantActivityOpenTarget: Identifiable, Equatable, Sendable {
    let kind: AssistantActivityOpenTargetKind
    let label: String
    let url: URL
    let detail: String?

    var id: String {
        "\(kind.rawValue)-\(url.absoluteString)"
    }
}

struct AssistantTimelineImagePreview: Identifiable, Equatable, Sendable {
    let url: URL
    let label: String
    let detail: String?
    let data: Data

    var id: String {
        url.standardizedFileURL.path
    }
}

func assistantActivityOpenTargets(
    for activity: AssistantActivityItem,
    sessionCWD: String? = nil
) -> [AssistantActivityOpenTarget] {
    let rawDetails = activity.rawDetails?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .nonEmpty

    switch activity.kind {
    case .webSearch:
        guard let query = rawDetails,
              let url = assistantSearchURL(for: query) else {
            return []
        }
        return [
            AssistantActivityOpenTarget(
                kind: .webSearch,
                label: query,
                url: url,
                detail: "Open search"
            )
        ]

    default:
        guard let rawDetails else { return [] }

        let fileTargets = assistantResolvedFileTargets(
            from: rawDetails,
            sessionCWD: sessionCWD
        )
        if !fileTargets.isEmpty {
            return fileTargets
        }

        if let url = assistantFirstURL(in: rawDetails) {
            return [
                AssistantActivityOpenTarget(
                    kind: .url,
                    label: assistantURLDisplayLabel(url),
                    url: url,
                    detail: url.absoluteString
                )
            ]
        }

        return []
    }
}

func assistantActivityImagePreviews(
    for activity: AssistantActivityItem,
    sessionCWD: String? = nil,
    maxCount: Int = 3
) -> [AssistantTimelineImagePreview] {
    assistantImagePreviews(
        from: assistantActivityOpenTargets(for: activity, sessionCWD: sessionCWD),
        maxCount: maxCount
    )
}

func assistantImagePreviews(
    from openTargets: [AssistantActivityOpenTarget],
    maxCount: Int = 3
) -> [AssistantTimelineImagePreview] {
    let limitedTargets = assistantImageOpenTargets(from: openTargets, maxCount: maxCount)

    return limitedTargets.compactMap { target in
        guard let data = assistantLoadImageData(from: target.url) else { return nil }
        return AssistantTimelineImagePreview(
            url: target.url,
            label: target.label,
            detail: target.detail,
            data: data
        )
    }
}

func assistantImageAttachments(
    from openTargets: [AssistantActivityOpenTarget],
    maxCount: Int = 3
) -> [Data] {
    assistantImagePreviews(from: openTargets, maxCount: maxCount).map(\.data)
}

func assistantActivityImageAttachments(
    for activity: AssistantActivityItem,
    sessionCWD: String? = nil,
    maxCount: Int = 3
) -> [Data] {
    assistantActivityImagePreviews(
        for: activity,
        sessionCWD: sessionCWD,
        maxCount: maxCount
    ).map(\.data)
}

func assistantTimelineImageAttachments(
    matchingReplyText replyText: String?,
    in items: [AssistantTimelineItem]
) -> [Data] {
    guard !items.isEmpty,
          let anchorText = replyText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty else {
        return []
    }

    guard let anchorItem = items.reversed().first(where: { item in
        assistantTimelineTextsLikelyMatch(
            item.text?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            anchorText
        )
    }) else {
        return []
    }

    if let anchorTurnID = anchorItem.turnID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
        return items.reversed().compactMap { item -> [Data]? in
            guard item.turnID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty == anchorTurnID,
                  let images = item.imageAttachments,
                  !images.isEmpty else {
                return nil
            }
            return images
        }.first ?? []
    }

    return anchorItem.imageAttachments ?? []
}

private func assistantTimelineTextsLikelyMatch(
    _ lhs: String?,
    _ rhs: String?
) -> Bool {
    guard let lhs = assistantNormalizedTimelineText(lhs),
          let rhs = assistantNormalizedTimelineText(rhs) else {
        return false
    }

    if lhs == rhs {
        return true
    }

    let shorterLength = min(lhs.count, rhs.count)
    guard shorterLength >= 24 else { return false }

    if let lhsPrefix = assistantTimelineTruncatedPrefix(lhs),
       rhs.hasPrefix(lhsPrefix) {
        return true
    }

    if let rhsPrefix = assistantTimelineTruncatedPrefix(rhs),
       lhs.hasPrefix(rhsPrefix) {
        return true
    }

    return lhs.contains(rhs) || rhs.contains(lhs)
}

private func assistantNormalizedTimelineText(_ text: String?) -> String? {
    guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
        return nil
    }

    let collapsed = text.replacingOccurrences(
        of: #"\s+"#,
        with: " ",
        options: .regularExpression
    )
    return collapsed.lowercased()
}

private func assistantTimelineTruncatedPrefix(_ text: String) -> String? {
    if let range = text.range(of: "...") {
        let prefix = text[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix.count >= 24 ? String(prefix) : nil
    }

    if let range = text.range(of: "…") {
        let prefix = text[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix.count >= 24 ? String(prefix) : nil
    }

    return nil
}

private func assistantResolvedFileTargets(
    from rawDetails: String,
    sessionCWD: String?
) -> [AssistantActivityOpenTarget] {
    var results: [AssistantActivityOpenTarget] = []
    var seen = Set<String>()

    for candidate in assistantExtractFilePathCandidates(from: rawDetails) {
        guard let fileURL = assistantResolvedFileURL(
            from: candidate,
            sessionCWD: sessionCWD
        ) else {
            continue
        }

        let key = fileURL.standardizedFileURL.path
        guard seen.insert(key).inserted else { continue }

        let basePath = sessionCWD?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
        let detail: String?
        if let basePath,
           key.hasPrefix(basePath + "/") {
            detail = String(key.dropFirst(basePath.count + 1))
        } else {
            detail = key
        }

        results.append(
            AssistantActivityOpenTarget(
                kind: .file,
                label: fileURL.lastPathComponent,
                url: fileURL,
                detail: detail
            )
        )
    }

    return results
}

private func assistantImageOpenTargets(
    from targets: [AssistantActivityOpenTarget],
    maxCount: Int
) -> [AssistantActivityOpenTarget] {
    let normalizedMaxCount = max(1, maxCount)
    var results: [AssistantActivityOpenTarget] = []

    for target in targets where target.kind == .file || target.url.isFileURL {
        guard assistantFileURLLooksLikeImage(target.url) else { continue }
        results.append(target)
        if results.count >= normalizedMaxCount {
            break
        }
    }

    return results
}

private func assistantExtractFilePathCandidates(from rawDetails: String) -> [String] {
    let normalized = rawDetails.replacingOccurrences(of: "\r\n", with: "\n")
    let lines = normalized.split(whereSeparator: \.isNewline)
    var candidates: [String] = []
    var seen = Set<String>()

    func append(_ candidate: String) {
        let normalizedCandidate = assistantNormalizedPathCandidate(candidate)
        guard let normalizedCandidate, seen.insert(normalizedCandidate).inserted else { return }
        candidates.append(normalizedCandidate)
    }

    for rawLine in lines {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { continue }

        if let gitStylePath = assistantFirstRegexCapture(
            in: line,
            pattern: #"^(?:[MADRCU?]{1,2}|\+\+\+\s+[ab]/|---\s+[ab]/)\s+(.+)$"#
        ) {
            append(gitStylePath)
        }

        if let patchPath = assistantFirstRegexCapture(
            in: line,
            pattern: #"^\*\*\* (?:Update|Add|Delete) File: (.+)$"#
        ) {
            append(patchPath)
        }

        if assistantLooksLikeStandalonePath(line) {
            append(line)
        }

        for match in assistantRegexMatches(
            in: line,
            pattern: #"(?:/|(?:[A-Za-z0-9._-]+/)+)[A-Za-z0-9._-]+\.[A-Za-z][A-Za-z0-9]{0,7}"#
        ) {
            append(match)
        }

        for match in assistantRegexMatches(
            in: line,
            pattern: #"(?<![\w/])(?:[A-Za-z0-9._-]+\.)[A-Za-z][A-Za-z0-9]{0,7}(?![\w])"#
        ) {
            append(match)
        }
    }

    return candidates
}

private func assistantLooksLikeStandalonePath(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.nonEmpty != nil else { return false }
    guard !trimmed.contains(" ") else { return false }
    guard trimmed.contains("/") || trimmed.contains(".") else { return false }
    return !trimmed.lowercased().hasPrefix("http://") && !trimmed.lowercased().hasPrefix("https://")
}

private func assistantResolvedFileURL(
    from candidate: String,
    sessionCWD: String?
) -> URL? {
    let normalized = assistantNormalizedPathCandidate(candidate)
    guard let normalized else { return nil }

    if normalized.lowercased().hasPrefix("file://"),
       let fileURL = URL(string: normalized),
       fileURL.isFileURL,
       FileManager.default.fileExists(atPath: fileURL.path) {
        return fileURL.standardizedFileURL
    }

    if normalized.hasPrefix("/") {
        let absoluteURL = URL(fileURLWithPath: normalized)
        guard FileManager.default.fileExists(atPath: absoluteURL.path) else { return nil }
        return absoluteURL.standardizedFileURL
    }

    let candidateRoots = [
        sessionCWD?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
        FileManager.default.currentDirectoryPath
    ].compactMap { $0 }

    for root in candidateRoots {
        let resolved = URL(fileURLWithPath: root)
            .appendingPathComponent(normalized)
            .standardizedFileURL
        if FileManager.default.fileExists(atPath: resolved.path) {
            return resolved
        }
    }

    return nil
}

private func assistantFileURLLooksLikeImage(_ url: URL) -> Bool {
    guard url.isFileURL else { return false }
    let pathExtension = url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !pathExtension.isEmpty,
          let type = UTType(filenameExtension: pathExtension) else {
        return false
    }
    return type.conforms(to: .image)
}

private func assistantLoadImageData(from fileURL: URL) -> Data? {
    let standardizedURL = fileURL.standardizedFileURL
    guard FileManager.default.fileExists(atPath: standardizedURL.path) else { return nil }
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: standardizedURL.path),
          let byteCount = attributes[.size] as? NSNumber,
          byteCount.intValue <= 16_000_000 else {
        return nil
    }

    return try? Data(contentsOf: standardizedURL, options: [.mappedIfSafe])
}

private func assistantNormalizedPathCandidate(_ candidate: String) -> String? {
    var value = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }

    value = value
        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`()[]{}<>"))
        .replacingOccurrences(
            of: #"^(?:[MADRCU?]{1,2}|\+\+\+\s+[ab]/|---\s+[ab]/)\s+"#,
            with: "",
            options: .regularExpression
        )
        .replacingOccurrences(
            of: #"^\*\*\* (?:Update|Add|Delete) File: "#,
            with: "",
            options: .regularExpression
        )
        .replacingOccurrences(
            of: #"(#L\d+(?:C\d+)?|:\d+(?::\d+)?)$"#,
            with: "",
            options: .regularExpression
        )
        .trimmingCharacters(in: CharacterSet(charactersIn: ".,:;"))

    if value.hasPrefix("a/") || value.hasPrefix("b/") {
        value.removeFirst(2)
    }

    return value.nonEmpty
}

private func assistantSearchURL(for query: String) -> URL? {
    var components = URLComponents(string: "https://www.google.com/search")
    components?.queryItems = [URLQueryItem(name: "q", value: query)]
    return components?.url
}

private func assistantFirstURL(in text: String) -> URL? {
    guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
        return nil
    }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return detector
        .matches(in: text, options: [], range: range)
        .compactMap(\.url)
        .first
}

private func assistantURLDisplayLabel(_ url: URL) -> String {
    if let host = url.host?.nonEmpty {
        return host
    }
    return url.absoluteString
}

private func assistantRegexMatches(in text: String, pattern: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.matches(in: text, options: [], range: range).compactMap {
        guard let matchRange = Range($0.range, in: text) else { return nil }
        return String(text[matchRange])
    }
}

private func assistantFirstRegexCapture(in text: String, pattern: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, options: [], range: range),
          match.numberOfRanges > 1,
          let captureRange = Range(match.range(at: 1), in: text) else {
        return nil
    }
    return String(text[captureRange])
}

enum AssistantTimelineItemKind: String, Codable, Sendable {
    case userMessage
    case assistantProgress
    case assistantFinal
    case activity
    case permission
    case plan
    case system
}

struct AssistantTimelineItem: Identifiable, Equatable, Codable, Sendable {
    let id: String
    var sessionID: String?
    var turnID: String?
    var kind: AssistantTimelineItemKind
    var createdAt: Date
    var updatedAt: Date
    var text: String?
    var isStreaming: Bool
    var emphasis: Bool
    var activity: AssistantActivityItem?
    var permissionRequest: AssistantPermissionRequest?
    var planText: String?
    var planEntries: [AssistantPlanEntry]?
    var imageAttachments: [Data]?
    var providerBackend: AssistantRuntimeBackend?
    var providerModelID: String?
    var source: AssistantTimelineSource

    var sortDate: Date {
        activity?.startedAt ?? createdAt
    }

    var lastUpdatedAt: Date {
        activity?.updatedAt ?? updatedAt
    }

    var cacheable: Bool {
        switch kind {
        case .assistantProgress, .activity, .permission, .plan, .system:
            return true
        case .userMessage, .assistantFinal:
            return false
        }
    }

    init(
        id: String,
        sessionID: String?,
        turnID: String?,
        kind: AssistantTimelineItemKind,
        createdAt: Date,
        updatedAt: Date,
        text: String?,
        isStreaming: Bool,
        emphasis: Bool,
        activity: AssistantActivityItem?,
        permissionRequest: AssistantPermissionRequest?,
        planText: String?,
        planEntries: [AssistantPlanEntry]?,
        imageAttachments: [Data]? = nil,
        providerBackend: AssistantRuntimeBackend? = nil,
        providerModelID: String? = nil,
        source: AssistantTimelineSource
    ) {
        self.id = id
        self.sessionID = sessionID
        self.turnID = turnID
        self.kind = kind
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.text = text
        self.isStreaming = isStreaming
        self.emphasis = emphasis
        self.activity = activity
        self.permissionRequest = permissionRequest
        self.planText = planText
        self.planEntries = planEntries
        self.imageAttachments = imageAttachments
        self.providerBackend = providerBackend
        self.providerModelID = providerModelID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        self.source = source
    }

    static func userMessage(
        id: String = UUID().uuidString,
        sessionID: String?,
        turnID: String? = nil,
        text: String,
        createdAt: Date = Date(),
        imageAttachments: [Data]? = nil,
        providerBackend: AssistantRuntimeBackend? = nil,
        providerModelID: String? = nil,
        source: AssistantTimelineSource
    ) -> AssistantTimelineItem {
        AssistantTimelineItem(
            id: id,
            sessionID: sessionID,
            turnID: turnID,
            kind: .userMessage,
            createdAt: createdAt,
            updatedAt: createdAt,
            text: text,
            isStreaming: false,
            emphasis: false,
            activity: nil,
            permissionRequest: nil,
            planText: nil,
            planEntries: nil,
            imageAttachments: imageAttachments,
            providerBackend: providerBackend,
            providerModelID: providerModelID,
            source: source
        )
    }

    static func assistantProgress(
        id: String,
        sessionID: String?,
        turnID: String? = nil,
        text: String,
        createdAt: Date,
        updatedAt: Date = Date(),
        isStreaming: Bool,
        providerBackend: AssistantRuntimeBackend? = nil,
        providerModelID: String? = nil,
        source: AssistantTimelineSource
    ) -> AssistantTimelineItem {
        AssistantTimelineItem(
            id: id,
            sessionID: sessionID,
            turnID: turnID,
            kind: .assistantProgress,
            createdAt: createdAt,
            updatedAt: updatedAt,
            text: text,
            isStreaming: isStreaming,
            emphasis: false,
            activity: nil,
            permissionRequest: nil,
            planText: nil,
            planEntries: nil,
            providerBackend: providerBackend,
            providerModelID: providerModelID,
            source: source
        )
    }

    static func assistantFinal(
        id: String,
        sessionID: String?,
        turnID: String? = nil,
        text: String,
        createdAt: Date,
        updatedAt: Date = Date(),
        isStreaming: Bool,
        imageAttachments: [Data]? = nil,
        providerBackend: AssistantRuntimeBackend? = nil,
        providerModelID: String? = nil,
        source: AssistantTimelineSource
    ) -> AssistantTimelineItem {
        AssistantTimelineItem(
            id: id,
            sessionID: sessionID,
            turnID: turnID,
            kind: .assistantFinal,
            createdAt: createdAt,
            updatedAt: updatedAt,
            text: text,
            isStreaming: isStreaming,
            emphasis: false,
            activity: nil,
            permissionRequest: nil,
            planText: nil,
            planEntries: nil,
            imageAttachments: imageAttachments,
            providerBackend: providerBackend,
            providerModelID: providerModelID,
            source: source
        )
    }

    static func activity(_ activity: AssistantActivityItem) -> AssistantTimelineItem {
        AssistantTimelineItem(
            id: activity.id,
            sessionID: activity.sessionID,
            turnID: activity.turnID,
            kind: .activity,
            createdAt: activity.startedAt,
            updatedAt: activity.updatedAt,
            text: nil,
            isStreaming: activity.isActive,
            emphasis: false,
            activity: activity,
            permissionRequest: nil,
            planText: nil,
            planEntries: nil,
            providerBackend: nil,
            providerModelID: nil,
            source: activity.source
        )
    }

    static func permission(
        id: String,
        sessionID: String?,
        turnID: String? = nil,
        request: AssistantPermissionRequest,
        createdAt: Date = Date(),
        source: AssistantTimelineSource
    ) -> AssistantTimelineItem {
        AssistantTimelineItem(
            id: id,
            sessionID: sessionID,
            turnID: turnID,
            kind: .permission,
            createdAt: createdAt,
            updatedAt: createdAt,
            text: nil,
            isStreaming: false,
            emphasis: true,
            activity: nil,
            permissionRequest: request,
            planText: nil,
            planEntries: nil,
            providerBackend: nil,
            providerModelID: nil,
            source: source
        )
    }

    static func plan(
        id: String,
        sessionID: String?,
        turnID: String? = nil,
        text: String,
        entries: [AssistantPlanEntry]? = nil,
        createdAt: Date,
        updatedAt: Date = Date(),
        isStreaming: Bool,
        source: AssistantTimelineSource
    ) -> AssistantTimelineItem {
        AssistantTimelineItem(
            id: id,
            sessionID: sessionID,
            turnID: turnID,
            kind: .plan,
            createdAt: createdAt,
            updatedAt: updatedAt,
            text: nil,
            isStreaming: isStreaming,
            emphasis: false,
            activity: nil,
            permissionRequest: nil,
            planText: text,
            planEntries: entries,
            providerBackend: nil,
            providerModelID: nil,
            source: source
        )
    }

    static func system(
        id: String = UUID().uuidString,
        sessionID: String?,
        turnID: String? = nil,
        text: String,
        createdAt: Date = Date(),
        emphasis: Bool = false,
        imageAttachments: [Data]? = nil,
        source: AssistantTimelineSource
    ) -> AssistantTimelineItem {
        AssistantTimelineItem(
            id: id,
            sessionID: sessionID,
            turnID: turnID,
            kind: .system,
            createdAt: createdAt,
            updatedAt: createdAt,
            text: text,
            isStreaming: false,
            emphasis: emphasis,
            activity: nil,
            permissionRequest: nil,
            planText: nil,
            planEntries: nil,
            imageAttachments: imageAttachments,
            providerBackend: nil,
            providerModelID: nil,
            source: source
        )
    }
}

enum AssistantPermissionCardState: Equatable, Sendable {
    case waitingForApproval
    case waitingForInput
    case completed
    case notActive

    var cardTitle: String {
        switch self {
        case .waitingForApproval, .completed, .notActive:
            return "Permission Needed"
        case .waitingForInput:
            return "Input Needed"
        }
    }

    var badgeTitle: String {
        switch self {
        case .waitingForApproval, .waitingForInput:
            return "Waiting"
        case .completed:
            return "Handled"
        case .notActive:
            return "Not Active"
        }
    }
}

func assistantPermissionCardState(
    for request: AssistantPermissionRequest,
    pendingRequest: AssistantPermissionRequest?,
    sessionStatus: AssistantSessionStatus?
) -> AssistantPermissionCardState {
    if assistantPermissionRequestsMatch(request, pendingRequest) {
        return request.toolKind == "userInput" ? .waitingForInput : .waitingForApproval
    }

    if sessionStatus == .completed {
        return .completed
    }

    return .notActive
}

private func assistantPermissionRequestsMatch(
    _ lhs: AssistantPermissionRequest,
    _ rhs: AssistantPermissionRequest?
) -> Bool {
    guard let rhs else { return false }
    guard lhs.id == rhs.id else { return false }

    let lhsSessionID = lhs.sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
    let rhsSessionID = rhs.sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
    if lhsSessionID.isEmpty || rhsSessionID.isEmpty {
        return true
    }

    return lhsSessionID.caseInsensitiveCompare(rhsSessionID) == .orderedSame
}

enum AssistantTimelineMutation: Equatable, Sendable {
    case reset(sessionID: String?)
    case upsert(AssistantTimelineItem)
    case appendTextDelta(
        id: String,
        sessionID: String?,
        turnID: String?,
        kind: AssistantTimelineItemKind,
        delta: String,
        createdAt: Date,
        updatedAt: Date,
        isStreaming: Bool,
        emphasis: Bool,
        source: AssistantTimelineSource
    )
    case remove(id: String)
}

struct AssistantSessionActivityStore {
    private struct PersistedSnapshot: Codable {
        var version: Int
        var items: [AssistantTimelineItem]
    }

    let fileManager: FileManager
    let homeDirectory: URL

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
    }

    func loadTimeline(sessionID: String) -> [AssistantTimelineItem] {
        guard let fileURL = fileURL(for: sessionID),
              let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(PersistedSnapshot.self, from: data) else {
            return []
        }

        return snapshot.items
            .filter(\.cacheable)
            .sorted(by: timelineSort)
    }

    func saveTimeline(_ items: [AssistantTimelineItem], sessionID: String) {
        guard let fileURL = fileURL(for: sessionID) else { return }

        let filteredItems = items
            .filter(\.cacheable)
            .sorted(by: timelineSort)

        do {
            try fileManager.createDirectory(
                at: storageDirectory,
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(
                PersistedSnapshot(version: 1, items: filteredItems)
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Best effort cache only.
        }
    }

    func deleteTimeline(sessionID: String) {
        guard let fileURL = fileURL(for: sessionID) else { return }
        try? fileManager.removeItem(at: fileURL)
    }

    private var storageDirectory: URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("OpenAssist", isDirectory: true)
            .appendingPathComponent("AssistantActivity", isDirectory: true)
    }

    private func fileURL(for sessionID: String) -> URL? {
        guard let sessionID = sessionID.nonEmpty else { return nil }
        let safeName = sessionID.replacingOccurrences(of: "/", with: "_")
        return storageDirectory.appendingPathComponent("\(safeName).json")
    }
}

private func timelineSort(_ lhs: AssistantTimelineItem, _ rhs: AssistantTimelineItem) -> Bool {
    if lhs.sortDate != rhs.sortDate {
        return lhs.sortDate < rhs.sortDate
    }
    if lhs.lastUpdatedAt != rhs.lastUpdatedAt {
        return lhs.lastUpdatedAt < rhs.lastUpdatedAt
    }
    return lhs.id < rhs.id
}
