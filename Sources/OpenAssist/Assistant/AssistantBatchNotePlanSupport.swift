import Foundation

enum AssistantNoteType: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case master
    case note
    case decision
    case task
    case reference
    case question

    var displayLabel: String {
        switch self {
        case .master:
            return "Master"
        case .note:
            return "Note"
        case .decision:
            return "Decision"
        case .task:
            return "Task"
        case .reference:
            return "Reference"
        case .question:
            return "Question"
        }
    }

    static func normalized(_ rawValue: String?) -> AssistantNoteType? {
        guard let rawValue = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !rawValue.isEmpty else {
            return nil
        }
        return AssistantNoteType(rawValue: rawValue)
    }
}

struct AssistantBatchNotePlanSourceContext: Equatable, Sendable {
    let ref: String
    let target: AssistantNoteLinkTarget
    let title: String
    let noteType: AssistantNoteType
    let sourceLabel: String
    let markdown: String
}

enum AssistantBatchNotePlanLinkTargetKind: String, Codable, Equatable, Hashable, Sendable {
    case proposed
    case source
}

struct AssistantBatchNotePlanDraftLinkTarget: Codable, Equatable, Sendable {
    let kind: AssistantBatchNotePlanLinkTargetKind
    let ref: String
}

struct AssistantBatchNotePlanDraftNote: Codable, Equatable, Sendable {
    let tempID: String
    let title: String
    let noteType: AssistantNoteType
    let markdown: String
    let sourceNoteRefs: [String]

    private enum CodingKeys: String, CodingKey {
        case tempID = "tempId"
        case title
        case noteType
        case markdown
        case sourceNoteRefs
    }
}

struct AssistantBatchNotePlanDraftLink: Codable, Equatable, Sendable {
    let fromTempID: String
    let toTarget: AssistantBatchNotePlanDraftLinkTarget

    private enum CodingKeys: String, CodingKey {
        case fromTempID = "fromTempId"
        case toTarget
    }
}

struct AssistantBatchNotePlanDraftOutput: Codable, Equatable, Sendable {
    let notes: [AssistantBatchNotePlanDraftNote]
    let links: [AssistantBatchNotePlanDraftLink]
}

enum AssistantBatchNotePlanGenerationResult {
    case success(AssistantBatchNotePlanDraftOutput)
    case failure(String)
}

struct AssistantBatchNotePlanGraphNode: Equatable, Sendable {
    let id: String
    let title: String
    let kind: AssistantBatchNotePlanLinkTargetKind
    let noteType: AssistantNoteType?
}

struct AssistantBatchNotePlanGraphEdge: Equatable, Sendable {
    let fromNodeID: String
    let toNodeID: String
}

struct AssistantBatchNotePlanComposedLink: Equatable, Sendable {
    let title: String
    let href: String
}

enum AssistantBatchNotePlanParser {
    enum ParseError: LocalizedError, Equatable {
        case invalidJSON
        case missingNotes
        case emptyTempID
        case duplicateTempID(String)
        case invalidNoteType(String)
        case emptyTitle(String)
        case emptyMarkdown(String)
        case invalidSourceReference(String)
        case missingMasterNote
        case multipleMasterNotes
        case invalidLinkSource(String)
        case invalidLinkTarget(String)

        var errorDescription: String? {
            switch self {
            case .invalidJSON:
                return "AI returned JSON in an unexpected format."
            case .missingNotes:
                return "AI did not return any notes."
            case .emptyTempID:
                return "AI returned a note without a temp id."
            case .duplicateTempID(let value):
                return "AI returned duplicate temp id '\(value)'."
            case .invalidNoteType(let value):
                return "AI returned an unsupported note type '\(value)'."
            case .emptyTitle(let value):
                return "AI returned an empty title for note '\(value)'."
            case .emptyMarkdown(let value):
                return "AI returned empty markdown for note '\(value)'."
            case .invalidSourceReference(let value):
                return "AI referenced an unknown source note '\(value)'."
            case .missingMasterNote:
                return "AI must return exactly one master note."
            case .multipleMasterNotes:
                return "AI returned more than one master note."
            case .invalidLinkSource(let value):
                return "AI returned a link from an unknown note '\(value)'."
            case .invalidLinkTarget(let value):
                return "AI returned a link to an unknown target '\(value)'."
            }
        }
    }

    static func parseResponse(
        _ response: String,
        allowedSourceRefs: Set<String>
    ) throws -> AssistantBatchNotePlanDraftOutput {
        let normalized = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let jsonText = extractJSONObject(from: normalized),
              let data = jsonText.data(using: .utf8) else {
            throw ParseError.invalidJSON
        }

        let decoder = JSONDecoder()
        let rawOutput: RawOutput
        do {
            rawOutput = try decoder.decode(RawOutput.self, from: data)
        } catch {
            throw ParseError.invalidJSON
        }

        guard !rawOutput.notes.isEmpty else {
            throw ParseError.missingNotes
        }

        var noteIDs = Set<String>()
        var masterCount = 0
        var notes: [AssistantBatchNotePlanDraftNote] = []

        for rawNote in rawOutput.notes {
            let normalizedTempID = rawNote.tempID.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalizedTempID.isEmpty {
                throw ParseError.emptyTempID
            }
            let normalizedKey = normalizedTempID.lowercased()
            if !noteIDs.insert(normalizedKey).inserted {
                throw ParseError.duplicateTempID(normalizedTempID)
            }

            let normalizedNoteType = AssistantNoteType.normalized(rawNote.noteType)
            guard let noteType = normalizedNoteType else {
                throw ParseError.invalidNoteType(rawNote.noteType)
            }

            if rawNote.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ParseError.emptyTitle(normalizedTempID)
            }
            if rawNote.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ParseError.emptyMarkdown(normalizedTempID)
            }

            if noteType == .master {
                masterCount += 1
            }

            for ref in rawNote.sourceNoteRefs {
                let normalizedRef = ref.trimmingCharacters(in: .whitespacesAndNewlines)
                if !allowedSourceRefs.contains(normalizedRef) {
                    throw ParseError.invalidSourceReference(normalizedRef)
                }
            }

            notes.append(
                AssistantBatchNotePlanDraftNote(
                    tempID: rawNote.tempID,
                    title: rawNote.title,
                    noteType: noteType,
                    markdown: rawNote.markdown,
                    sourceNoteRefs: rawNote.sourceNoteRefs
                )
            )
        }

        if masterCount == 0 {
            throw ParseError.missingMasterNote
        }
        if masterCount > 1 {
            throw ParseError.multipleMasterNotes
        }

        var links: [AssistantBatchNotePlanDraftLink] = []
        for rawLink in rawOutput.links {
            guard let targetKind = AssistantBatchNotePlanLinkTargetKind(
                rawValue: rawLink.toTarget.kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            ) else {
                throw ParseError.invalidLinkTarget(rawLink.toTarget.kind)
            }

            let link = AssistantBatchNotePlanDraftLink(
                fromTempID: rawLink.fromTempID,
                toTarget: AssistantBatchNotePlanDraftLinkTarget(
                    kind: targetKind,
                    ref: rawLink.toTarget.ref
                )
            )
            let normalizedFrom = link.fromTempID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !noteIDs.contains(normalizedFrom.lowercased()) {
                throw ParseError.invalidLinkSource(normalizedFrom)
            }

            let normalizedTargetRef = link.toTarget.ref.trimmingCharacters(in: .whitespacesAndNewlines)
            switch link.toTarget.kind {
            case .proposed:
                if !noteIDs.contains(normalizedTargetRef.lowercased()) {
                    throw ParseError.invalidLinkTarget(normalizedTargetRef)
                }
            case .source:
                if !allowedSourceRefs.contains(normalizedTargetRef) {
                    throw ParseError.invalidLinkTarget(normalizedTargetRef)
                }
            }

            links.append(link)
        }

        return AssistantBatchNotePlanDraftOutput(notes: notes, links: links)
    }

    private struct RawOutput: Codable {
        let notes: [RawNote]
        let links: [RawLink]
    }

    private struct RawNote: Codable {
        let tempID: String
        let title: String
        let noteType: String
        let markdown: String
        let sourceNoteRefs: [String]

        private enum CodingKeys: String, CodingKey {
            case tempID = "tempId"
            case title
            case noteType
            case markdown
            case sourceNoteRefs
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            tempID = try container.decode(String.self, forKey: .tempID)
            title = try container.decode(String.self, forKey: .title)
            noteType = try container.decode(String.self, forKey: .noteType)
            markdown = try container.decode(String.self, forKey: .markdown)
            sourceNoteRefs = try container.decodeIfPresent([String].self, forKey: .sourceNoteRefs) ?? []
        }
    }

    private struct RawLink: Codable {
        let fromTempID: String
        let toTarget: RawLinkTarget

        private enum CodingKeys: String, CodingKey {
            case fromTempID = "fromTempId"
            case toTarget
        }
    }

    private struct RawLinkTarget: Codable {
        let kind: String
        let ref: String
    }

    private static func extractJSONObject(from response: String) -> String? {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"), trimmed.hasSuffix("}") {
            return trimmed
        }

        if trimmed.hasPrefix("```"),
           let fencedRange = trimmed.range(of: "```", options: [], range: trimmed.index(trimmed.startIndex, offsetBy: 3)..<trimmed.endIndex) {
            let inner = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 3)..<fencedRange.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let stripped = inner.hasPrefix("json")
                ? inner.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines)
                : String(inner)
            if stripped.hasPrefix("{"), stripped.hasSuffix("}") {
                return stripped
            }
        }

        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}") else {
            return nil
        }
        let candidate = String(trimmed[start...end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.hasPrefix("{") && candidate.hasSuffix("}") ? candidate : nil
    }
}

enum AssistantBatchNotePlanComposer {
    static func deduplicatedTitles(
        _ titles: [String],
        reservedTitles: Set<String> = []
    ) -> [String] {
        var seen = Set(reservedTitles.map { normalizedTitleKey($0) })
        var result: [String] = []

        for title in titles {
            let base = normalizedDisplayTitle(title)
            var candidate = base
            var suffix = 2
            while seen.contains(normalizedTitleKey(candidate)) {
                candidate = "\(base) (\(suffix))"
                suffix += 1
            }
            seen.insert(normalizedTitleKey(candidate))
            result.append(candidate)
        }

        return result
    }

    static func composeMarkdown(
        baseMarkdown: String,
        sourceLinks: [AssistantBatchNotePlanComposedLink],
        relatedLinks: [AssistantBatchNotePlanComposedLink]
    ) -> String {
        var sections: [String] = []
        let trimmedBase = baseMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedBase.isEmpty {
            sections.append(trimmedBase)
        }

        if !sourceLinks.isEmpty {
            sections.append(
                """
                ## Sources
                \(bulletList(for: sourceLinks))
                """
            )
        }

        if !relatedLinks.isEmpty {
            sections.append(
                """
                ## Related Notes
                \(bulletList(for: relatedLinks))
                """
            )
        }

        return sections.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func buildPreviewGraph(
        nodes: [AssistantBatchNotePlanGraphNode],
        edges: [AssistantBatchNotePlanGraphEdge]
    ) -> AssistantNoteGraphPayload? {
        guard !nodes.isEmpty else { return nil }

        let orderedNodes = nodes.sorted { lhs, rhs in
            if lhs.kind != rhs.kind {
                return lhs.kind == .proposed
            }
            if lhs.noteType == .master || rhs.noteType == .master {
                return lhs.noteType == .master
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }

        let orderedEdges = edges.sorted {
            if $0.fromNodeID == $1.fromNodeID {
                return $0.toNodeID < $1.toNodeID
            }
            return $0.fromNodeID < $1.fromNodeID
        }

        var nodeIDsByID: [String: String] = [:]
        for (index, node) in orderedNodes.enumerated() {
            nodeIDsByID[node.id] = "N\(index)"
        }

        var lines: [String] = ["flowchart LR"]
        for node in orderedNodes {
            guard let nodeID = nodeIDsByID[node.id] else { continue }
            lines.append("  \(nodeID)[\"\(escapeMermaidLabel(node.title))\"]")
        }

        for edge in orderedEdges {
            guard let fromID = nodeIDsByID[edge.fromNodeID],
                  let toID = nodeIDsByID[edge.toNodeID] else {
                continue
            }
            lines.append("  \(fromID) --> \(toID)")
        }

        lines.append("  classDef source fill:#7c87961c,stroke:#7c8796,stroke-width:1px;")
        lines.append("  classDef proposed fill:#6aa6ff1f,stroke:#6aa6ff,stroke-width:1.4px;")
        lines.append("  classDef master fill:#f59e0b22,stroke:#f59e0b,stroke-width:2px;")

        let sourceNodeIDs = orderedNodes.compactMap { node -> String? in
            guard node.kind == .source else { return nil }
            return nodeIDsByID[node.id]
        }
        if !sourceNodeIDs.isEmpty {
            lines.append("  class \(sourceNodeIDs.joined(separator: ",")) source;")
        }

        let proposedNodeIDs = orderedNodes.compactMap { node -> String? in
            guard node.kind == .proposed, node.noteType != .master else { return nil }
            return nodeIDsByID[node.id]
        }
        if !proposedNodeIDs.isEmpty {
            lines.append("  class \(proposedNodeIDs.joined(separator: ",")) proposed;")
        }

        let masterNodeIDs = orderedNodes.compactMap { node -> String? in
            guard node.noteType == .master else { return nil }
            return nodeIDsByID[node.id]
        }
        if !masterNodeIDs.isEmpty {
            lines.append("  class \(masterNodeIDs.joined(separator: ",")) master;")
        }

        return AssistantNoteGraphPayload(
            mermaidCode: lines.joined(separator: "\n"),
            nodeCount: orderedNodes.count,
            edgeCount: orderedEdges.count
        )
    }

    private static func bulletList(
        for links: [AssistantBatchNotePlanComposedLink]
    ) -> String {
        links.map { "- \(markdownLink(label: $0.title, href: $0.href))" }
            .joined(separator: "\n")
    }

    private static func markdownLink(label: String, href: String) -> String {
        let normalizedLabel = label
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "[\(normalizedLabel)](\(href))"
    }

    private static func normalizedDisplayTitle(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled note" : title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedTitleKey(_ title: String) -> String {
        normalizedDisplayTitle(title).lowercased()
    }

    private static func escapeMermaidLabel(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
