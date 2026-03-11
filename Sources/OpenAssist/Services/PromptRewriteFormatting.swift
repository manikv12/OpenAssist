import Foundation

enum PromptRewriteFormatting {
    private enum PreferredStructure {
        case plain
        case bulletList
        case numberedList
        case questionList
    }

    static func prepareSuggestedTextForInsertion(
        _ suggestedText: String,
        originalText: String,
        forceMarkdown: Bool
    ) -> String {
        var normalized = normalizeText(suggestedText)
        guard !normalized.isEmpty else { return "" }

        let preferredStructure = structurePreference(for: originalText)
        normalized = applyPreferredStructureIfNeeded(normalized, preferredStructure: preferredStructure)

        if forceMarkdown {
            normalized = convertToMarkdown(normalized, preferredStructure: preferredStructure)
        }

        return normalizeText(normalized)
    }

    static func prepareEditedTextForInsertion(
        _ editedText: String,
        forceMarkdown: Bool
    ) -> String {
        var normalized = normalizeText(editedText)
        guard !normalized.isEmpty else { return "" }

        if forceMarkdown {
            normalized = convertToMarkdown(normalized, preferredStructure: .plain)
        }

        return normalizeText(normalized)
    }

    private static func normalizeText(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized
    }

    private static func structurePreference(for originalText: String) -> PreferredStructure {
        let normalized = normalizeText(originalText)
        guard !normalized.isEmpty else { return .plain }

        let lines = normalized
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return .plain }

        let bulletCount = lines.filter { isBulletLine($0) }.count
        if bulletCount >= 1 {
            return .bulletList
        }

        let numberedCount = lines.filter { isNumberedLine($0) }.count
        if numberedCount >= 1 {
            return .numberedList
        }

        let questionCount = lines.filter { isQuestionLikeLine($0) }.count
        if questionCount >= 2 || (questionCount >= 1 && lines.count >= 2) {
            return .questionList
        }

        return .plain
    }

    private static func applyPreferredStructureIfNeeded(
        _ text: String,
        preferredStructure: PreferredStructure
    ) -> String {
        switch preferredStructure {
        case .plain:
            return text
        case .bulletList:
            guard !containsListMarkers(text) else { return text }
            let segments = responseSegments(from: text)
            guard segments.count > 1 else { return text }
            return segments.map { "- \(stripListPrefix(from: $0))" }.joined(separator: "\n")
        case .numberedList:
            guard !containsNumberedList(text) else { return text }
            let segments = responseSegments(from: text)
            guard segments.count > 1 else { return text }
            return segments.enumerated().map { index, segment in
                "\(index + 1). \(stripListPrefix(from: segment))"
            }.joined(separator: "\n")
        case .questionList:
            if containsListMarkers(text) || hasQuestionPerLine(text) {
                return text
            }
            let segments = responseSegments(from: text)
            guard segments.count > 1 else { return text }
            return segments.map { segment in
                "- \(ensureQuestionSuffixIfNeeded(stripListPrefix(from: segment)))"
            }.joined(separator: "\n")
        }
    }

    private static func convertToMarkdown(
        _ text: String,
        preferredStructure: PreferredStructure
    ) -> String {
        var normalized = normalizeListMarkers(in: text)

        if !isMarkdownLike(normalized) {
            switch preferredStructure {
            case .bulletList, .questionList:
                let segments = responseSegments(from: normalized)
                if segments.count > 1 {
                    normalized = segments.map { "- \(stripListPrefix(from: $0))" }.joined(separator: "\n")
                }
            case .numberedList:
                let segments = responseSegments(from: normalized)
                if segments.count > 1 {
                    normalized = segments.enumerated().map { index, segment in
                        "\(index + 1). \(stripListPrefix(from: segment))"
                    }.joined(separator: "\n")
                }
            case .plain:
                break
            }
        }

        return normalizeText(normalized)
    }

    private static func normalizeListMarkers(in text: String) -> String {
        var output = text
        output = output.replacingOccurrences(
            of: #"(?m)^\s*[•*]\s+"#,
            with: "- ",
            options: .regularExpression
        )
        output = output.replacingOccurrences(
            of: #"(?m)^\s*[-–—]\s+"#,
            with: "- ",
            options: .regularExpression
        )
        output = output.replacingOccurrences(
            of: #"(?m)^\s*(\d+)\)\s+"#,
            with: "$1. ",
            options: .regularExpression
        )
        return output
    }

    private static func responseSegments(from text: String) -> [String] {
        let normalized = normalizeText(text)
        guard !normalized.isEmpty else { return [] }

        let lineSegments = normalized
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if lineSegments.count > 1 {
            return lineSegments
        }

        let sentenceSplit = normalized
            .split(whereSeparator: { character in
                character == "." || character == "!" || character == "?" || character == ";"
            })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if sentenceSplit.count > 1 {
            return sentenceSplit
        }

        let commaSplit = normalized
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if commaSplit.count > 1 {
            return commaSplit
        }

        return [normalized]
    }

    private static func isMarkdownLike(_ text: String) -> Bool {
        if text.contains("```") {
            return true
        }

        let patterns = [
            #"(?m)^\s{0,3}#{1,6}\s+\S+"#,
            #"(?m)^\s{0,3}(?:[-*+]\s+\S+|\d+\.\s+\S+|>\s+\S+)"#,
            #"\[[^\]]+\]\([^)]+\)"#
        ]
        return patterns.contains { pattern in
            text.range(of: pattern, options: .regularExpression) != nil
        }
    }

    private static func containsListMarkers(_ text: String) -> Bool {
        text.range(
            of: #"(?m)^\s{0,3}(?:[-*+]\s+\S+|\d+[.)]\s+\S+)"#,
            options: .regularExpression
        ) != nil
    }

    private static func containsNumberedList(_ text: String) -> Bool {
        text.range(
            of: #"(?m)^\s{0,3}\d+[.)]\s+\S+"#,
            options: .regularExpression
        ) != nil
    }

    private static func hasQuestionPerLine(_ text: String) -> Bool {
        let lines = text
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.count >= 2 else { return false }
        return lines.filter { isQuestionLikeLine($0) }.count >= 2
    }

    private static func isBulletLine(_ line: String) -> Bool {
        line.range(of: #"^\s*[-*•]\s+\S+"#, options: .regularExpression) != nil
    }

    private static func isNumberedLine(_ line: String) -> Bool {
        line.range(of: #"^\s*\d+[.)]\s+\S+"#, options: .regularExpression) != nil
    }

    private static func isQuestionLikeLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasSuffix("?") {
            return true
        }

        let normalized = trimmed.lowercased()
        let prefixes = [
            "what ", "why ", "how ", "when ", "where ", "who ", "which ",
            "can ", "could ", "should ", "would ", "do ", "does ", "did ",
            "is ", "are ", "am ", "was ", "were ", "will ", "may "
        ]
        return prefixes.contains { normalized.hasPrefix($0) }
    }

    private static func stripListPrefix(from line: String) -> String {
        var value = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = [
            #"^\s*[-*•]\s+"#,
            #"^\s*\d+[.)]\s+"#
        ]
        for pattern in patterns {
            value = value.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func ensureQuestionSuffixIfNeeded(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if trimmed.hasSuffix("?") || trimmed.hasSuffix("!") || trimmed.hasSuffix(".") {
            return trimmed
        }

        if isQuestionLikeLine(trimmed) {
            return trimmed + "?"
        }
        return trimmed
    }
}
