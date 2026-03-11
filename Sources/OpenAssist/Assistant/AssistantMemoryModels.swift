import Foundation

enum AssistantMemoryEntryType: String, Codable, CaseIterable, Sendable {
    case lesson
    case preference
    case constraint
    case entity

    var label: String {
        switch self {
        case .lesson:
            return "Lesson"
        case .preference:
            return "Preference"
        case .constraint:
            return "Constraint"
        case .entity:
            return "Entity"
        }
    }
}

enum AssistantMemoryEntryState: String, Codable, CaseIterable, Sendable {
    case active
    case invalidated
}

struct AssistantMemoryEntry: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let provider: MemoryProviderKind
    let scopeKey: String
    let bundleID: String
    let projectKey: String?
    let identityKey: String?
    let threadID: String?
    let memoryType: AssistantMemoryEntryType
    let title: String
    let summary: String
    let detail: String
    let keywords: [String]
    let confidence: Double
    let state: AssistantMemoryEntryState
    let metadata: [String: String]
    let createdAt: Date
    let updatedAt: Date

    init(
        id: UUID = UUID(),
        provider: MemoryProviderKind = .codex,
        scopeKey: String,
        bundleID: String,
        projectKey: String? = nil,
        identityKey: String? = nil,
        threadID: String? = nil,
        memoryType: AssistantMemoryEntryType,
        title: String,
        summary: String,
        detail: String,
        keywords: [String] = [],
        confidence: Double = 0.6,
        state: AssistantMemoryEntryState = .active,
        metadata: [String: String] = [:],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.provider = provider
        self.scopeKey = scopeKey
        self.bundleID = bundleID
        self.projectKey = projectKey
        self.identityKey = identityKey
        self.threadID = threadID
        self.memoryType = memoryType
        self.title = title
        self.summary = summary
        self.detail = detail
        self.keywords = keywords
        self.confidence = confidence
        self.state = state
        self.metadata = metadata
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

enum AssistantMemorySuggestionKind: String, Codable, CaseIterable, Sendable {
    case reviewedLesson
    case reviewedFailure
    case manualSave

    var label: String {
        switch self {
        case .reviewedLesson:
            return "Suggested lesson"
        case .reviewedFailure:
            return "Failure lesson"
        case .manualSave:
            return "Saved from chat"
        }
    }
}

struct AssistantMemorySuggestion: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let threadID: String
    let kind: AssistantMemorySuggestionKind
    let memoryType: AssistantMemoryEntryType
    let title: String
    let summary: String
    let detail: String
    let scopeKey: String
    let bundleID: String
    let projectKey: String?
    let identityKey: String?
    let keywords: [String]
    let confidence: Double
    let sourceExcerpt: String?
    let metadata: [String: String]
    let createdAt: Date

    init(
        id: UUID = UUID(),
        threadID: String,
        kind: AssistantMemorySuggestionKind,
        memoryType: AssistantMemoryEntryType,
        title: String,
        summary: String,
        detail: String,
        scopeKey: String,
        bundleID: String,
        projectKey: String? = nil,
        identityKey: String? = nil,
        keywords: [String] = [],
        confidence: Double = 0.6,
        sourceExcerpt: String? = nil,
        metadata: [String: String] = [:],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.threadID = threadID
        self.kind = kind
        self.memoryType = memoryType
        self.title = title
        self.summary = summary
        self.detail = detail
        self.scopeKey = scopeKey
        self.bundleID = bundleID
        self.projectKey = projectKey
        self.identityKey = identityKey
        self.keywords = keywords
        self.confidence = confidence
        self.sourceExcerpt = sourceExcerpt
        self.metadata = metadata
        self.createdAt = createdAt
    }

    func asEntry(updatedAt: Date = Date()) -> AssistantMemoryEntry {
        var mergedMetadata = metadata
        mergedMetadata["memory_domain"] = "assistant"
        mergedMetadata["suggestion_kind"] = kind.rawValue
        return AssistantMemoryEntry(
            provider: .codex,
            scopeKey: scopeKey,
            bundleID: bundleID,
            projectKey: projectKey,
            identityKey: identityKey,
            threadID: threadID,
            memoryType: memoryType,
            title: title,
            summary: summary,
            detail: detail,
            keywords: keywords,
            confidence: confidence,
            state: .active,
            metadata: mergedMetadata,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

enum AssistantThreadMemorySection: String, CaseIterable, Sendable {
    case currentTask = "Current task"
    case activeFacts = "Active facts"
    case importantReferences = "Important names / files / services"
    case sessionPreferences = "Session preferences"
    case staleNotes = "Stale notes"
    case candidateLessons = "Candidate lessons"
}

struct AssistantThreadMemoryDocument: Equatable, Sendable {
    var currentTask: String
    var activeFacts: [String]
    var importantReferences: [String]
    var sessionPreferences: [String]
    var staleNotes: [String]
    var candidateLessons: [String]

    static let empty = AssistantThreadMemoryDocument(
        currentTask: "",
        activeFacts: [],
        importantReferences: [],
        sessionPreferences: [],
        staleNotes: [],
        candidateLessons: []
    )

    init(
        currentTask: String = "",
        activeFacts: [String] = [],
        importantReferences: [String] = [],
        sessionPreferences: [String] = [],
        staleNotes: [String] = [],
        candidateLessons: [String] = []
    ) {
        self.currentTask = currentTask
        self.activeFacts = activeFacts
        self.importantReferences = importantReferences
        self.sessionPreferences = sessionPreferences
        self.staleNotes = staleNotes
        self.candidateLessons = candidateLessons
    }

    var hasMeaningfulContent: Bool {
        !currentTask.isEmpty
            || !activeFacts.isEmpty
            || !importantReferences.isEmpty
            || !sessionPreferences.isEmpty
            || !candidateLessons.isEmpty
    }

    var markdown: String {
        var sections: [String] = []
        sections.append("# \(AssistantThreadMemorySection.currentTask.rawValue)\n\(currentTask.isEmpty ? "_Add the current task here._" : currentTask)")
        sections.append(renderListSection(.activeFacts, items: activeFacts, placeholder: "_Add short facts that are still true for this task._"))
        sections.append(renderListSection(.importantReferences, items: importantReferences, placeholder: "_Add file names, services, or important names here._"))
        sections.append(renderListSection(.sessionPreferences, items: sessionPreferences, placeholder: "_Add preferences learned in this session._"))
        sections.append(renderListSection(.staleNotes, items: staleNotes, placeholder: "_Moved here when the task changes or old notes become stale._"))
        sections.append(renderListSection(.candidateLessons, items: candidateLessons, placeholder: "_Potential long-term lessons waiting for review._"))
        return sections.joined(separator: "\n\n")
    }

    mutating func addCandidateLesson(_ lesson: String) {
        let normalized = AssistantThreadMemoryDocument.normalizedLine(lesson)
        guard !normalized.isEmpty else { return }
        if !candidateLessons.contains(where: { $0.caseInsensitiveCompare(normalized) == .orderedSame }) {
            candidateLessons.append(normalized)
        }
    }

    mutating func removeCandidateLesson(_ lesson: String) {
        let normalized = AssistantThreadMemoryDocument.normalizedLine(lesson)
        candidateLessons.removeAll { $0.caseInsensitiveCompare(normalized) == .orderedSame }
    }

    mutating func moveActiveContentToStale(reason: String?) {
        var movedNotes: [String] = []
        if !currentTask.isEmpty {
            movedNotes.append("Previous task: \(currentTask)")
        }
        movedNotes.append(contentsOf: activeFacts)
        movedNotes.append(contentsOf: importantReferences)
        if let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
            movedNotes.insert("Reset reason: \(reason)", at: 0)
        }
        for note in movedNotes {
            let normalized = AssistantThreadMemoryDocument.normalizedLine(note)
            guard !normalized.isEmpty else { continue }
            if !staleNotes.contains(where: { $0.caseInsensitiveCompare(normalized) == .orderedSame }) {
                staleNotes.append(normalized)
            }
        }
        currentTask = ""
        activeFacts = []
        importantReferences = []
    }

    static func parse(markdown: String) -> AssistantThreadMemoryDocument {
        let normalizedText = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let headings = AssistantThreadMemorySection.allCases
        var bodies: [AssistantThreadMemorySection: String] = [:]

        for (index, section) in headings.enumerated() {
            let heading = "# \(section.rawValue)"
            guard let headingRange = normalizedText.range(of: heading) else {
                continue
            }
            let bodyStart = headingRange.upperBound
            let sectionSlice = normalizedText[bodyStart...]
            // Find the nearest subsequent heading that is actually present,
            // not just the immediately next enum case.
            var bodyEnd = normalizedText.endIndex
            for laterIndex in (index + 1)..<headings.count {
                if let nextRange = sectionSlice.range(of: "\n# \(headings[laterIndex].rawValue)") {
                    bodyEnd = nextRange.lowerBound
                    break
                }
            }
            let body = normalizedText[bodyStart..<bodyEnd]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            bodies[section] = body
        }

        return AssistantThreadMemoryDocument(
            currentTask: normalizedBody(bodies[.currentTask] ?? ""),
            activeFacts: parseListBody(bodies[.activeFacts] ?? ""),
            importantReferences: parseListBody(bodies[.importantReferences] ?? ""),
            sessionPreferences: parseListBody(bodies[.sessionPreferences] ?? ""),
            staleNotes: parseListBody(bodies[.staleNotes] ?? ""),
            candidateLessons: parseListBody(bodies[.candidateLessons] ?? "")
        )
    }

    static func normalizedTask(_ value: String) -> String {
        normalizedBody(value)
    }

    static func normalizedLine(_ value: String) -> String {
        MemoryTextNormalizer.collapsedWhitespace(
            value
                .replacingOccurrences(of: #"^\s*[-*]\s*"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func normalizedBody(_ value: String) -> String {
        let cleaned = value
            .replacingOccurrences(of: "_Add the current task here._", with: "")
            .replacingOccurrences(of: "_Add short facts that are still true for this task._", with: "")
            .replacingOccurrences(of: "_Add file names, services, or important names here._", with: "")
            .replacingOccurrences(of: "_Add preferences learned in this session._", with: "")
            .replacingOccurrences(of: "_Moved here when the task changes or old notes become stale._", with: "")
            .replacingOccurrences(of: "_Potential long-term lessons waiting for review._", with: "")
        return MemoryTextNormalizer.collapsedWhitespace(cleaned)
    }

    private static func parseListBody(_ body: String) -> [String] {
        body
            .split(separator: "\n")
            .map { normalizedLine(String($0)) }
            .filter { !$0.isEmpty && !$0.hasPrefix("_") }
    }

    private func renderListSection(
        _ section: AssistantThreadMemorySection,
        items: [String],
        placeholder: String
    ) -> String {
        let body: String
        if items.isEmpty {
            body = placeholder
        } else {
            body = items.map { "- \($0)" }.joined(separator: "\n")
        }
        return "# \(section.rawValue)\n\(body)"
    }
}

struct AssistantBuiltMemoryContext: Sendable {
    let summary: String?
    let statusMessage: String?
    let fileURL: URL?
    let fileChangedExternally: Bool
    let resetPerformed: Bool
    let scope: MemoryScopeContext
}
