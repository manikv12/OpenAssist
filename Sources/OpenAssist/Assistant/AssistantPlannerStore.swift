import CryptoKit
import Foundation

struct AssistantPlannerDateContext: Equatable, Sendable {
    let date: Date
    let dayID: String
    let displayDate: String
    let weekday: String
    let month: String
    let yesterdayID: String
    let tomorrowID: String
}

struct AssistantPlannerStyleTokens: Codable, Equatable, Sendable {
    var name: String?
    var colors: [String: String]
    var typography: [String: [String: String]]
    var spacing: [String: String]
    var rounded: [String: String]
    var warning: String?

    static let empty = AssistantPlannerStyleTokens(
        name: nil,
        colors: [:],
        typography: [:],
        spacing: [:],
        rounded: [:],
        warning: nil
    )

    var isEmpty: Bool {
        name == nil && colors.isEmpty && typography.isEmpty && spacing.isEmpty && rounded.isEmpty
    }
}

struct AssistantPlannerTemplate: Equatable, Sendable {
    let id: String
    let title: String
    let markdown: String
}

struct AssistantPlannerDay: Equatable, Sendable {
    let dateContext: AssistantPlannerDateContext
    let note: AssistantNoteSummary
    let markdown: String
    let fileURL: URL
}

enum AssistantPlannerScheduleMode: String, Equatable, Sendable {
    case move
    case copy
    case link
}

struct AssistantPlannerScheduleRequest: Equatable, Sendable {
    let mode: AssistantPlannerScheduleMode
    let targetDayID: String
    let selectedMarkdown: String
    let sourceTarget: AssistantNoteLinkTarget?
    let sourceTitle: String?
    let sourceTextAfterMove: String?
    let originalDayID: String?
}

struct AssistantPlannerPreview: Equatable, Sendable {
    let id: String
    let kind: String
    let targetDayID: String?
    let noteID: String?
    let markdown: String
    let summary: String
}

enum AssistantPlannerStoreError: LocalizedError, Equatable {
    case invalidDate(String)
    case previewNotFound
    case invalidPreview

    var errorDescription: String? {
        switch self {
        case .invalidDate:
            return "Choose a valid planner date."
        case .previewNotFound:
            return "That planner preview could not be found."
        case .invalidPreview:
            return "Open Assist could not apply that planner preview."
        }
    }
}

final class AssistantPlannerStore {
    static let ownerID = "global"
    static let defaultTemplateID = "default"

    private enum StorageName {
        static let plannerRoot = "Planner"
        static let daily = "Daily"
        static let templates = "Templates"
        static let recovery = "Recovery"
        static let design = "DESIGN.md"
        static let defaultTemplate = "default.md"
    }

    private let fileManager: FileManager
    private let rootURL: URL
    private let recoveryStore: AssistantNoteRecoveryStore
    private let calendar: Calendar
    private var previews: [String: AssistantPlannerPreview] = [:]

    init(
        fileManager: FileManager = .default,
        baseDirectoryURL: URL? = nil,
        calendar: Calendar = Calendar.autoupdatingCurrent
    ) {
        self.fileManager = fileManager
        if let baseDirectoryURL {
            self.rootURL = baseDirectoryURL.appendingPathComponent(StorageName.plannerRoot, isDirectory: true)
        } else {
            let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory())
                    .appendingPathComponent("Library/Application Support", isDirectory: true)
            self.rootURL = applicationSupport
                .appendingPathComponent("OpenAssist", isDirectory: true)
                .appendingPathComponent(StorageName.plannerRoot, isDirectory: true)
        }
        self.calendar = calendar
        self.recoveryStore = AssistantNoteRecoveryStore(
            fileManager: fileManager,
            recoveryRootURL: rootURL.appendingPathComponent(StorageName.recovery, isDirectory: true)
        )
    }

    var plannerRootURL: URL { rootURL }

    func designFileURL() -> URL {
        rootURL.appendingPathComponent(StorageName.design, isDirectory: false)
    }

    func dayMarkdownFileURL(dayID: String) -> URL {
        dayFileURL(dayID: dayID)
    }

    func dayID(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 1970,
            components.month ?? 1,
            components.day ?? 1
        )
    }

    func date(from dayID: String) throws -> Date {
        let parts = dayID.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { throw AssistantPlannerStoreError.invalidDate(dayID) }
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        components.hour = 12
        guard let date = calendar.date(from: components) else {
            throw AssistantPlannerStoreError.invalidDate(dayID)
        }
        return date
    }

    func dateContext(for date: Date) -> AssistantPlannerDateContext {
        let normalizedDate = calendar.startOfDay(for: date)
        let dayID = dayID(for: normalizedDate)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: normalizedDate) ?? normalizedDate
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: normalizedDate) ?? normalizedDate
        let displayFormatter = DateFormatter()
        displayFormatter.calendar = calendar
        displayFormatter.timeZone = calendar.timeZone
        displayFormatter.dateFormat = "EEEE, MMMM d, yyyy"
        let weekdayFormatter = DateFormatter()
        weekdayFormatter.calendar = calendar
        weekdayFormatter.timeZone = calendar.timeZone
        weekdayFormatter.dateFormat = "EEEE"
        let monthFormatter = DateFormatter()
        monthFormatter.calendar = calendar
        monthFormatter.timeZone = calendar.timeZone
        monthFormatter.dateFormat = "MMMM"
        return AssistantPlannerDateContext(
            date: normalizedDate,
            dayID: dayID,
            displayDate: displayFormatter.string(from: normalizedDate),
            weekday: weekdayFormatter.string(from: normalizedDate),
            month: monthFormatter.string(from: normalizedDate),
            yesterdayID: self.dayID(for: yesterday),
            tomorrowID: self.dayID(for: tomorrow)
        )
    }

    func loadWorkspace(for date: Date = Date(), createIfMissing: Bool = true) throws -> AssistantNotesWorkspace {
        let day = try loadDay(for: date, createIfMissing: createIfMissing)
        return workspace(selectedDay: day)
    }

    func loadWorkspace(dayID: String, createIfMissing: Bool = true) throws -> AssistantNotesWorkspace {
        let date = try date(from: dayID)
        return try loadWorkspace(for: date, createIfMissing: createIfMissing)
    }

    func loadDay(for date: Date = Date(), createIfMissing: Bool = true) throws -> AssistantPlannerDay {
        try ensureBaseFiles()
        let context = dateContext(for: date)
        let fileURL = dayFileURL(dayID: context.dayID)
        if createIfMissing && !fileManager.fileExists(atPath: fileURL.path) {
            try writeText(renderDefaultTemplate(for: context), to: fileURL)
        }
        let markdown = loadText(from: fileURL)
        return AssistantPlannerDay(
            dateContext: context,
            note: noteSummary(for: context, fileURL: fileURL, markdown: markdown),
            markdown: markdown,
            fileURL: fileURL
        )
    }

    func loadDay(dayID: String, createIfMissing: Bool = true) throws -> AssistantPlannerDay {
        let date = try date(from: dayID)
        return try loadDay(for: date, createIfMissing: createIfMissing)
    }

    func loadStoredNotes(limit: Int? = nil) throws -> [AssistantStoredNote] {
        let dayIDs = discoverDayIDs().sorted(by: >)
        let selectedDayIDs = limit.map { Array(dayIDs.prefix(max(0, $0))) } ?? dayIDs
        return try selectedDayIDs.map { dayID in
            let date = try date(from: dayID)
            let day = try loadDay(for: date, createIfMissing: false)
            return AssistantStoredNote(
                ownerKind: .planner,
                ownerID: Self.ownerID,
                noteID: day.note.id,
                title: day.note.title,
                noteType: .task,
                fileName: day.note.fileName,
                folderID: day.note.folderID,
                updatedAt: day.note.updatedAt,
                text: day.markdown
            )
        }
    }

    @discardableResult
    func saveDay(
        dayID: String,
        text: String,
        forceHistorySnapshot: Bool = false,
        now: Date = Date()
    ) throws -> AssistantNotesWorkspace {
        let date = try date(from: dayID)
        let current = try loadDay(for: date, createIfMissing: true)
        let normalizedText = normalizeNewlines(text)
        if current.markdown != normalizedText {
            recoveryStore.captureHistorySnapshot(
                note: current.note,
                ownerKind: .planner,
                ownerID: Self.ownerID,
                text: current.markdown,
                at: now,
                force: forceHistorySnapshot
            )
            try writeText(normalizedText, to: current.fileURL)
        }
        let reloaded = try loadDay(for: date, createIfMissing: true)
        return workspace(selectedDay: reloaded)
    }

    @discardableResult
    func appendScheduledItem(_ request: AssistantPlannerScheduleRequest) throws -> AssistantNotesWorkspace {
        let targetDate = try date(from: request.targetDayID)
        let day = try loadDay(for: targetDate, createIfMissing: true)
        let insertion = scheduledMarkdown(for: request)
        let updated = insertPlannerBlock(insertion, into: day.markdown)
        return try saveDay(dayID: request.targetDayID, text: updated, forceHistorySnapshot: true)
    }

    func historyVersions(dayID: String) -> [AssistantNoteHistoryVersion] {
        recoveryStore.historyVersions(
            ownerKind: .planner,
            ownerID: Self.ownerID,
            noteID: dayID
        )
    }

    @discardableResult
    func restoreHistoryVersion(dayID: String, versionID: String) throws -> AssistantNotesWorkspace? {
        guard let payload = recoveryStore.restoreHistoryVersion(
            ownerKind: .planner,
            ownerID: Self.ownerID,
            noteID: dayID,
            versionID: versionID
        ) else {
            return nil
        }
        return try saveDay(
            dayID: dayID,
            text: payload.text,
            forceHistorySnapshot: true
        )
    }

    @discardableResult
    func deleteHistoryVersion(dayID: String, versionID: String) throws -> AssistantNotesWorkspace {
        recoveryStore.deleteHistoryVersion(
            ownerKind: .planner,
            ownerID: Self.ownerID,
            noteID: dayID,
            versionID: versionID
        )
        return try loadWorkspace(dayID: dayID)
    }

    func prepareAdd(dayID: String, content: String) throws -> AssistantPlannerPreview {
        let preview = AssistantPlannerPreview(
            id: UUID().uuidString.lowercased(),
            kind: "add",
            targetDayID: dayID,
            noteID: nil,
            markdown: content.trimmingCharacters(in: .whitespacesAndNewlines),
            summary: "Add content to \(dayID)"
        )
        previews[preview.id] = preview
        return preview
    }

    func prepareCarryForward(from dayID: String, to targetDayID: String) throws -> AssistantPlannerPreview {
        let sourceDate = try date(from: dayID)
        let source = try loadDay(for: sourceDate, createIfMissing: false)
        let openTasks = Self.openTaskLines(in: source.markdown)
        let markdown = openTasks.joined(separator: "\n")
        let preview = AssistantPlannerPreview(
            id: UUID().uuidString.lowercased(),
            kind: "carry_forward",
            targetDayID: targetDayID,
            noteID: dayID,
            markdown: markdown,
            summary: "Carry \(openTasks.count) open task\(openTasks.count == 1 ? "" : "s") from \(dayID) to \(targetDayID)"
        )
        previews[preview.id] = preview
        return preview
    }

    @discardableResult
    func applyPreview(id: String) throws -> AssistantNotesWorkspace {
        guard let preview = previews.removeValue(forKey: id) else {
            throw AssistantPlannerStoreError.previewNotFound
        }
        guard let dayID = preview.targetDayID else {
            throw AssistantPlannerStoreError.invalidPreview
        }
        let request = AssistantPlannerScheduleRequest(
            mode: .copy,
            targetDayID: dayID,
            selectedMarkdown: preview.markdown,
            sourceTarget: nil,
            sourceTitle: nil,
            sourceTextAfterMove: nil,
            originalDayID: preview.noteID
        )
        return try appendScheduledItem(request)
    }

    func searchDays(query: String, limit: Int = 20) throws -> [AssistantStoredNote] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedQuery.isEmpty else {
            return try Array(loadStoredNotes(limit: limit).prefix(limit))
        }
        return try loadStoredNotes(limit: nil)
            .filter { note in
                note.title.lowercased().contains(normalizedQuery)
                    || note.text.lowercased().contains(normalizedQuery)
            }
            .prefix(limit)
            .map { $0 }
    }

    func listOpenTasks(limit: Int = 80) throws -> [String] {
        var tasks: [String] = []
        for note in try loadStoredNotes(limit: nil) {
            let lines = Self.openTaskLines(in: note.text).map { "\(note.noteID): \($0)" }
            tasks.append(contentsOf: lines)
            if tasks.count >= limit { break }
        }
        return Array(tasks.prefix(limit))
    }

    func loadStyleTokens() -> AssistantPlannerStyleTokens {
        let url = designFileURL()
        guard fileManager.fileExists(atPath: url.path),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return .empty
        }
        return Self.parseDesignMarkdown(text)
    }

    func ensureBaseFiles() throws {
        try fileManager.createDirectory(at: dailyRootURL(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: templatesRootURL(), withIntermediateDirectories: true)
        let templateURL = templatesRootURL().appendingPathComponent(StorageName.defaultTemplate, isDirectory: false)
        if !fileManager.fileExists(atPath: templateURL.path) {
            try defaultTemplateMarkdown.write(to: templateURL, atomically: true, encoding: .utf8)
        } else if shouldReplaceDefaultTemplate(loadText(from: templateURL)) {
            try defaultTemplateMarkdown.write(to: templateURL, atomically: true, encoding: .utf8)
        }
        let designURL = designFileURL()
        if !fileManager.fileExists(atPath: designURL.path) {
            try defaultDesignMarkdown.write(to: designURL, atomically: true, encoding: .utf8)
        }
    }

    static func parseDesignMarkdown(_ markdown: String) -> AssistantPlannerStyleTokens {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n") else {
            return .empty
        }
        guard let endRange = normalized.range(of: "\n---", options: [], range: normalized.index(normalized.startIndex, offsetBy: 4)..<normalized.endIndex) else {
            var tokens = AssistantPlannerStyleTokens.empty
            tokens.warning = "DESIGN.md frontmatter is incomplete, so the normal OpenAssist theme is being used."
            return tokens
        }
        let frontmatter = String(normalized[normalized.index(normalized.startIndex, offsetBy: 4)..<endRange.lowerBound])
        var tokens = AssistantPlannerStyleTokens.empty
        var group: String?
        var nestedGroup: String?
        for rawLine in frontmatter.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let indent = rawLine.prefix { $0 == " " }.count
            if indent == 0 {
                nestedGroup = nil
                if line.hasSuffix(":") {
                    group = String(line.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                    continue
                }
                let pair = splitYAMLPair(line)
                if pair.key == "name" {
                    tokens.name = pair.value
                }
                continue
            }
            guard let group else { continue }
            if indent == 2, line.hasSuffix(":") {
                nestedGroup = String(line.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                if group == "typography", let nestedGroup {
                    tokens.typography[nestedGroup] = tokens.typography[nestedGroup] ?? [:]
                }
                continue
            }
            let pair = splitYAMLPair(line)
            guard !pair.key.isEmpty else { continue }
            switch group {
            case "colors":
                if isHexColor(pair.value) {
                    tokens.colors[pair.key] = pair.value
                } else {
                    tokens.warning = "Some DESIGN.md color tokens were ignored because they were not hex colors."
                }
            case "spacing":
                tokens.spacing[pair.key] = pair.value
            case "rounded":
                tokens.rounded[pair.key] = pair.value
            case "typography":
                if let nestedGroup {
                    var typography = tokens.typography[nestedGroup] ?? [:]
                    typography[pair.key] = pair.value
                    tokens.typography[nestedGroup] = typography
                }
            default:
                continue
            }
        }
        return tokens
    }

    static func openTaskLines(in markdown: String) -> [String] {
        markdown.components(separatedBy: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("- [ ]") || trimmed.hasPrefix("* [ ]") else { return nil }
            return trimmed
        }
    }

    private static func templateFingerprint(_ markdown: String) -> String {
        markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func shouldReplaceDefaultTemplate(_ markdown: String) -> Bool {
        let fingerprint = Self.templateFingerprint(markdown)
        guard !fingerprint.isEmpty else { return true }
        return legacyTemplateMarkdowns.contains { Self.templateFingerprint($0) == fingerprint }
    }

    private func workspace(selectedDay: AssistantPlannerDay) -> AssistantNotesWorkspace {
        let notes = discoverDayIDs()
            .sorted(by: >)
            .compactMap { dayID -> AssistantNoteSummary? in
                guard let date = try? date(from: dayID),
                      let day = try? loadDay(for: date, createIfMissing: false) else {
                    return nil
                }
                return day.note
            }
        let orderedNotes = notes.isEmpty ? [selectedDay.note] : notes
        let manifest = AssistantNoteManifest(
            selectedNoteID: selectedDay.note.id,
            notes: orderedNotes,
            folders: []
        )
        return AssistantNotesWorkspace(
            ownerKind: .planner,
            ownerID: Self.ownerID,
            manifest: manifest,
            selectedNoteText: selectedDay.markdown
        )
    }

    private func renderDefaultTemplate(for context: AssistantPlannerDateContext) throws -> String {
        let templateURL = templatesRootURL().appendingPathComponent(StorageName.defaultTemplate, isDirectory: false)
        let template = loadText(from: templateURL).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? defaultTemplateMarkdown
            : loadText(from: templateURL)
        return Self.renderTemplate(template, context: context)
    }

    static func renderTemplate(_ template: String, context: AssistantPlannerDateContext) -> String {
        var rendered = template.replacingOccurrences(of: "\r\n", with: "\n")
        let replacements = [
            "{{date}}": context.displayDate,
            "{{isoDate}}": context.dayID,
            "{{weekday}}": context.weekday,
            "{{month}}": context.month,
            "{{yesterday}}": context.yesterdayID,
            "{{tomorrow}}": context.tomorrowID,
        ]
        for (token, value) in replacements {
            rendered = rendered.replacingOccurrences(of: token, with: value)
        }
        return rendered.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private func scheduledMarkdown(for request: AssistantPlannerScheduleRequest) -> String {
        let trimmed = request.selectedMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceLink: String? = request.sourceTarget.flatMap { target in
            AssistantNoteLinkCodec.markdownLink(
                label: request.sourceTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Source note",
                target: target
            )
        }
        let body: String
        if request.mode == .link, let sourceLink {
            body = "- \(sourceLink)"
        } else if trimmed.contains("\n") {
            body = trimmed
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("#") {
            body = trimmed
        } else {
            body = "- \(trimmed)"
        }
        let metadata = plannerMetadataComment(for: request, sourceLink: sourceLink)
        return [body, metadata].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty }
            .joined(separator: "\n")
    }

    private func insertPlannerBlock(_ block: String, into markdown: String) -> String {
        let section = targetSection(for: block)
        let normalizedBlock = block.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedBlock.isEmpty else { return markdown }
        var lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if let headingIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("## \(section)") == .orderedSame }) {
            var insertIndex = headingIndex + 1
            while insertIndex < lines.count {
                let trimmed = lines[insertIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("## ") { break }
                insertIndex += 1
            }
            let bodyRange = (headingIndex + 1)..<insertIndex
            let cleanedBody = Self.trimPlannerSectionBody(Array(lines[bodyRange]))
            lines.replaceSubrange(bodyRange, with: cleanedBody)
            insertIndex = headingIndex + 1 + cleanedBody.count
            let prefix = cleanedBody.isEmpty || cleanedBody.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true ? [] : [""]
            let insertion = prefix + normalizedBlock.components(separatedBy: "\n") + [""]
            lines.insert(contentsOf: insertion, at: insertIndex)
            return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        }
        let suffix = "\n\n## \(section)\n\(normalizedBlock)\n"
        return markdown.trimmingCharacters(in: .whitespacesAndNewlines) + suffix
    }

    private static func isEmptyPlannerPlaceholderLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("-") || trimmed.hasPrefix("*") else { return false }
        return trimmed.range(of: #"^[-*]\s*(?:\[[ xX]\]\s*)?$"#, options: .regularExpression) != nil
    }

    private static func trimPlannerSectionBody(_ lines: [String]) -> [String] {
        var cleaned = lines.filter { !isEmptyPlannerPlaceholderLine($0) }
        while cleaned.first?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            cleaned.removeFirst()
        }
        while cleaned.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            cleaned.removeLast()
        }
        return cleaned
    }

    private func targetSection(for block: String) -> String {
        let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(of: #"(?m)^\s*[-*]\s+\[[ xX]\]"#, options: .regularExpression) != nil {
            return "Tasks"
        }
        if trimmed.range(of: #"^\s*[-*]?\s*\[[^\]]+\]\(oa-note://open\?[^)]+\)\s*(<!--.*-->)?\s*$"#, options: .regularExpression) != nil {
            return "Linked Notes"
        }
        return "Notes"
    }

    private func plannerMetadataComment(for request: AssistantPlannerScheduleRequest, sourceLink: String?) -> String? {
        guard request.mode == .move || request.mode == .copy || request.mode == .link else { return nil }
        var fields = [
            "id=\"\(UUID().uuidString.lowercased())\"",
            "mode=\"\(request.mode.rawValue)\"",
            "targetDate=\"\(request.targetDayID)\"",
        ]
        if let originalDayID = request.originalDayID {
            fields.append("originalDate=\"\(originalDayID)\"")
        }
        if let sourceLink {
            fields.append("source=\"\(sourceLink.replacingOccurrences(of: "\"", with: "&quot;"))\"")
        }
        return "<!-- oa:planner \(fields.joined(separator: " ")) -->"
    }

    private func noteSummary(
        for context: AssistantPlannerDateContext,
        fileURL: URL,
        markdown: String
    ) -> AssistantNoteSummary {
        let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path)
        let updatedAt = attributes?[.modificationDate] as? Date ?? context.date
        let createdAt = attributes?[.creationDate] as? Date ?? context.date
        return AssistantNoteSummary(
            id: context.dayID,
            title: context.displayDate,
            noteType: .task,
            fileName: dailyRelativePath(dayID: context.dayID),
            folderID: nil,
            order: -(Int(context.dayID.replacingOccurrences(of: "-", with: "")) ?? 0),
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private func discoverDayIDs() -> [String] {
        let root = dailyRootURL()
        guard fileManager.fileExists(atPath: root.path),
              let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        var ids: [String] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "md" {
            let name = url.deletingPathExtension().lastPathComponent
            if (try? date(from: name)) != nil {
                ids.append(name)
            }
        }
        return Array(Set(ids))
    }

    private func dayFileURL(dayID: String) -> URL {
        let parts = dayID.split(separator: "-")
        let year = parts.indices.contains(0) ? String(parts[0]) : "1970"
        let month = parts.indices.contains(1) ? String(parts[1]) : "01"
        return dailyRootURL()
            .appendingPathComponent(year, isDirectory: true)
            .appendingPathComponent(month, isDirectory: true)
            .appendingPathComponent("\(dayID).md", isDirectory: false)
    }

    private func dailyRelativePath(dayID: String) -> String {
        let parts = dayID.split(separator: "-")
        let year = parts.indices.contains(0) ? String(parts[0]) : "1970"
        let month = parts.indices.contains(1) ? String(parts[1]) : "01"
        return "\(StorageName.daily)/\(year)/\(month)/\(dayID).md"
    }

    private func dailyRootURL() -> URL {
        rootURL.appendingPathComponent(StorageName.daily, isDirectory: true)
    }

    private func templatesRootURL() -> URL {
        rootURL.appendingPathComponent(StorageName.templates, isDirectory: true)
    }

    private func loadText(from url: URL) -> String {
        guard fileManager.fileExists(atPath: url.path),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }
        return normalizeNewlines(text)
    }

    private func writeText(_ text: String, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try normalizeNewlines(text).write(to: url, atomically: true, encoding: .utf8)
    }

    private func normalizeNewlines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
    }

    private static func splitYAMLPair(_ line: String) -> (key: String, value: String) {
        guard let separator = line.firstIndex(of: ":") else { return ("", "") }
        let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
        var value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
        }
        return (key, value)
    }

    private static func isHexColor(_ value: String) -> Bool {
        value.range(of: #"^#[0-9A-Fa-f]{3}([0-9A-Fa-f]{3})?$"#, options: .regularExpression) != nil
    }

    private var defaultTemplateMarkdown: String {
        """
        # {{date}}

        > Focus:
        """
    }

    private var legacyTemplateMarkdowns: [String] {
        [
            """
            # {{date}}

            > **Focus**
            > Choose one clear outcome for today.

            ## Top 3
            - [ ] First priority
            - [ ] Second priority
            - [ ] Third priority

            ## Schedule
            - 09:00 -
            - 13:00 -

            ## Tasks
            - [ ] Follow up on open work

            ## Notes
            - Add quick notes here.

            ## Journal
            What happened today?

            ## Linked Notes
            - Link related notes here.

            ## Done
            - [ ] Capture finished work
            """,
            """
            # {{date}}

            > Focus:

            ## Top 3
            - [ ]
            - [ ]
            - [ ]

            ## Schedule
            -

            ## Tasks
            - [ ]

            ## Notes
            -

            ## Journal
            What happened today?

            ## Linked Notes
            -

            ## Done
            - [ ]
            """
        ]
    }

    private var defaultDesignMarkdown: String {
        """
        ---
        version: alpha
        name: OpenAssist Daily Planner
        typography:
          body:
            fontFamily: SF Pro Text
            fontSize: 15px
            lineHeight: 1.7
        spacing:
          md: 16px
        rounded:
          md: 16px
        ---
        ## Overview
        A quiet daily planning surface that uses the active OpenAssist theme.
        """
    }
}
