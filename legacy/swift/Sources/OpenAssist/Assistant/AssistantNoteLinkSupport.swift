import Foundation

struct AssistantNoteLinkTarget: Codable, Equatable, Hashable, Sendable {
    let ownerKind: AssistantNoteOwnerKind
    let ownerID: String
    let noteID: String

    init(ownerKind: AssistantNoteOwnerKind, ownerID: String, noteID: String) {
        self.ownerKind = ownerKind
        self.ownerID = ownerID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.noteID = noteID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var storageKey: String {
        let normalizedOwnerID = ownerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedNoteID = noteID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(ownerKind.rawValue)::\(normalizedOwnerID)::\(normalizedNoteID)"
    }
}

struct AssistantStoredNote: Equatable, Sendable, Identifiable {
    let ownerKind: AssistantNoteOwnerKind
    let ownerID: String
    let noteID: String
    let title: String
    let noteType: AssistantNoteType
    let fileName: String
    let folderID: String?
    let updatedAt: Date
    let text: String

    init(
        ownerKind: AssistantNoteOwnerKind,
        ownerID: String,
        noteID: String,
        title: String,
        noteType: AssistantNoteType,
        fileName: String,
        folderID: String? = nil,
        updatedAt: Date,
        text: String
    ) {
        self.ownerKind = ownerKind
        self.ownerID = ownerID
        self.noteID = noteID
        self.title = title
        self.noteType = noteType
        self.fileName = fileName
        self.folderID = folderID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        self.updatedAt = updatedAt
        self.text = text
    }

    var id: String { target.storageKey }

    var target: AssistantNoteLinkTarget {
        AssistantNoteLinkTarget(
            ownerKind: ownerKind,
            ownerID: ownerID,
            noteID: noteID
        )
    }
}

struct AssistantParsedNoteLink: Equatable, Sendable, Hashable {
    let label: String
    let target: AssistantNoteLinkTarget
}

struct AssistantNoteRelationshipItem: Equatable, Sendable, Identifiable {
    let target: AssistantNoteLinkTarget
    let title: String
    let sourceLabel: String
    let isMissing: Bool
    let occurrenceCount: Int

    var id: String { target.storageKey }
}

struct AssistantNoteGraphPayload: Equatable, Sendable {
    let mermaidCode: String
    let nodeCount: Int
    let edgeCount: Int
}

struct AssistantNoteRelationshipSnapshot: Equatable, Sendable {
    let outgoingLinks: [AssistantNoteRelationshipItem]
    let backlinks: [AssistantNoteRelationshipItem]
    let graph: AssistantNoteGraphPayload?

    static let empty = AssistantNoteRelationshipSnapshot(
        outgoingLinks: [],
        backlinks: [],
        graph: nil
    )
}

enum AssistantNoteLinkCodec {
    static let scheme = "oa-note"
    private static let host = "open"
    private static let ownerKindKey = "ownerKind"
    private static let ownerIDKey = "ownerId"
    private static let noteIDKey = "noteId"

    static func urlString(for target: AssistantNoteLinkTarget) -> String {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = [
            URLQueryItem(name: ownerKindKey, value: target.ownerKind.rawValue),
            URLQueryItem(name: ownerIDKey, value: target.ownerID),
            URLQueryItem(name: noteIDKey, value: target.noteID),
        ]
        return components.string ?? ""
    }

    static func markdownLink(label: String, target: AssistantNoteLinkTarget) -> String {
        let normalizedLabel = sanitizeMarkdownLabel(label)
        return "[\(normalizedLabel)](\(urlString(for: target)))"
    }

    static func parseTarget(from urlString: String) -> AssistantNoteLinkTarget? {
        guard let components = URLComponents(string: urlString),
              components.scheme?.lowercased() == scheme,
              components.host?.lowercased() == host else {
            return nil
        }

        let queryItems: [String: String] = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap {
            guard let value = $0.value else { return nil }
            return ($0.name, value)
        })

        guard let ownerKindRaw = queryItems[ownerKindKey],
              let ownerKind = AssistantNoteOwnerKind(rawValue: ownerKindRaw),
              let ownerID = queryItems[ownerIDKey]?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).nonEmpty,
              let noteID = queryItems[noteIDKey]?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).nonEmpty else {
            return nil
        }

        return AssistantNoteLinkTarget(
            ownerKind: ownerKind,
            ownerID: ownerID,
            noteID: noteID
        )
    }

    static func isNoteURL(_ urlString: String) -> Bool {
        parseTarget(from: urlString) != nil
    }

    private static func sanitizeMarkdownLabel(_ label: String) -> String {
        label
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum AssistantNoteLinkParser {
    private static let linkExpression = try! NSRegularExpression(
        pattern: #"\[((?:\\.|[^\]])+)\]\((oa-note://open\?[^)\s]+)\)"#,
        options: [.caseInsensitive]
    )

    static func parseLinks(in markdown: String) -> [AssistantParsedNoteLink] {
        let range = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
        return linkExpression.matches(in: markdown, options: [], range: range).compactMap { match in
            guard match.numberOfRanges == 3,
                  let labelRange = Range(match.range(at: 1), in: markdown),
                  let urlRange = Range(match.range(at: 2), in: markdown) else {
                return nil
            }

            let label = markdown[labelRange]
                .replacingOccurrences(of: "\\[", with: "[")
                .replacingOccurrences(of: "\\]", with: "]")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let urlString = String(markdown[urlRange])
            guard let target = AssistantNoteLinkCodec.parseTarget(from: urlString) else {
                return nil
            }

            return AssistantParsedNoteLink(label: label, target: target)
        }
    }
}

enum AssistantNoteRelationshipBuilder {
    static func buildSnapshot(
        currentTarget: AssistantNoteLinkTarget,
        notes: [AssistantStoredNote],
        sourceLabelForOwner: (AssistantNoteOwnerKind, String) -> String
    ) -> AssistantNoteRelationshipSnapshot {
        let notesByTarget = Dictionary(uniqueKeysWithValues: notes.map { ($0.target, $0) })
        guard let currentNote = notesByTarget[currentTarget] else {
            return .empty
        }

        let outgoingOccurrences = collapseOutgoingLinks(
            AssistantNoteLinkParser.parseLinks(in: currentNote.text)
        )
        let outgoingItems = outgoingOccurrences.map { occurrence -> AssistantNoteRelationshipItem in
            if let targetNote = notesByTarget[occurrence.target] {
                return AssistantNoteRelationshipItem(
                    target: occurrence.target,
                    title: targetNote.title,
                    sourceLabel: sourceLabelForOwner(targetNote.ownerKind, targetNote.ownerID),
                    isMissing: false,
                    occurrenceCount: occurrence.count
                )
            }

            let fallbackTitle = occurrence.firstLabel.nonEmpty ?? "Missing note"
            return AssistantNoteRelationshipItem(
                target: occurrence.target,
                title: fallbackTitle,
                sourceLabel: "Missing note",
                isMissing: true,
                occurrenceCount: occurrence.count
            )
        }
        .sorted(by: relationshipSortComparator)

        let backlinkItems = notes
            .filter { $0.target != currentTarget }
            .compactMap { note -> AssistantNoteRelationshipItem? in
                let matchCount = AssistantNoteLinkParser.parseLinks(in: note.text)
                    .reduce(into: 0) { partialResult, link in
                        if link.target == currentTarget {
                            partialResult += 1
                        }
                    }
                guard matchCount > 0 else {
                    return nil
                }

                return AssistantNoteRelationshipItem(
                    target: note.target,
                    title: note.title,
                    sourceLabel: sourceLabelForOwner(note.ownerKind, note.ownerID),
                    isMissing: false,
                    occurrenceCount: matchCount
                )
            }
            .sorted(by: relationshipSortComparator)

        let graph = buildGraph(
            currentTarget: currentTarget,
            currentNote: currentNote,
            notesByTarget: notesByTarget,
            outgoingItems: outgoingItems,
            backlinkItems: backlinkItems
        )

        return AssistantNoteRelationshipSnapshot(
            outgoingLinks: outgoingItems,
            backlinks: backlinkItems,
            graph: graph
        )
    }

    private static func collapseOutgoingLinks(
        _ links: [AssistantParsedNoteLink]
    ) -> [(target: AssistantNoteLinkTarget, firstLabel: String, count: Int)] {
        var order: [AssistantNoteLinkTarget] = []
        var labelsByTarget: [AssistantNoteLinkTarget: String] = [:]
        var countsByTarget: [AssistantNoteLinkTarget: Int] = [:]

        for link in links {
            if countsByTarget[link.target] == nil {
                order.append(link.target)
                labelsByTarget[link.target] = link.label
            }
            countsByTarget[link.target, default: 0] += 1
        }

        return order.compactMap { target in
            guard let count = countsByTarget[target] else { return nil }
            return (target, labelsByTarget[target] ?? "", count)
        }
    }

    private static func buildGraph(
        currentTarget: AssistantNoteLinkTarget,
        currentNote: AssistantStoredNote,
        notesByTarget: [AssistantNoteLinkTarget: AssistantStoredNote],
        outgoingItems: [AssistantNoteRelationshipItem],
        backlinkItems: [AssistantNoteRelationshipItem]
    ) -> AssistantNoteGraphPayload? {
        var orderedTargets: [AssistantNoteLinkTarget] = [currentTarget]
        var targetSet: Set<AssistantNoteLinkTarget> = [currentTarget]
        var edges: [(from: AssistantNoteLinkTarget, to: AssistantNoteLinkTarget)] = []
        var edgeSet: Set<String> = []

        for item in outgoingItems where !item.isMissing {
            if targetSet.insert(item.target).inserted {
                orderedTargets.append(item.target)
            }
            let edgeKey = "\(currentTarget.storageKey)->\(item.target.storageKey)"
            if edgeSet.insert(edgeKey).inserted {
                edges.append((from: currentTarget, to: item.target))
            }
        }

        for item in backlinkItems where !item.isMissing {
            if targetSet.insert(item.target).inserted {
                orderedTargets.append(item.target)
            }
            let edgeKey = "\(item.target.storageKey)->\(currentTarget.storageKey)"
            if edgeSet.insert(edgeKey).inserted {
                edges.append((from: item.target, to: currentTarget))
            }
        }

        guard !edges.isEmpty else {
            return nil
        }

        var nodeIDsByTarget: [AssistantNoteLinkTarget: String] = [:]
        for (index, target) in orderedTargets.enumerated() {
            nodeIDsByTarget[target] = "N\(index)"
        }

        var lines: [String] = ["flowchart LR"]
        for target in orderedTargets {
            guard let nodeID = nodeIDsByTarget[target] else { continue }
            let note = notesByTarget[target] ?? currentNote
            lines.append("  \(nodeID)[\"\(escapeMermaidLabel(note.title))\"]")
        }

        for edge in edges {
            guard let fromID = nodeIDsByTarget[edge.from],
                  let toID = nodeIDsByTarget[edge.to] else {
                continue
            }
            lines.append("  \(fromID) --> \(toID)")
        }

        for target in orderedTargets {
            guard let nodeID = nodeIDsByTarget[target] else { continue }
            lines.append(
                "  click \(nodeID) href \"\(AssistantNoteLinkCodec.urlString(for: target))\" \"Open linked note\""
            )
        }

        lines.append("  classDef current fill:#f59e0b22,stroke:#f59e0b,stroke-width:2px;")
        if let currentNodeID = nodeIDsByTarget[currentTarget] {
            lines.append("  class \(currentNodeID) current;")
        }

        return AssistantNoteGraphPayload(
            mermaidCode: lines.joined(separator: "\n"),
            nodeCount: orderedTargets.count,
            edgeCount: edges.count
        )
    }

    private static func relationshipSortComparator(
        lhs: AssistantNoteRelationshipItem,
        rhs: AssistantNoteRelationshipItem
    ) -> Bool {
        if lhs.isMissing != rhs.isMissing {
            return !lhs.isMissing
        }
        let sourceCompare = lhs.sourceLabel.localizedCaseInsensitiveCompare(rhs.sourceLabel)
        if sourceCompare != .orderedSame {
            return sourceCompare == .orderedAscending
        }
        let titleCompare = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
        if titleCompare != .orderedSame {
            return titleCompare == .orderedAscending
        }
        return lhs.target.storageKey < rhs.target.storageKey
    }

    private static func escapeMermaidLabel(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
