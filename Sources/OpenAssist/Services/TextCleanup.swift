import Foundation

enum TextCleanupMode: String, CaseIterable, Identifiable {
    case light
    case aggressive

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .light: return "Light"
        case .aggressive: return "Aggressive"
        }
    }
}

enum TextCleanup {
    static func process(_ input: String, mode: TextCleanupMode) -> String {
        var text = input
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else { return "" }

        text = collapseSpaces(text)
        text = normalizePunctuationRuns(text)
        text = dedupeImmediateRepeatedWords(text)

        switch mode {
        case .light:
            text = capitalizeSentenceStarts(text)
        case .aggressive:
            text = collapseLineBreaks(text)
            text = capitalizeSentenceStarts(text)
            text = normalizeCommonContractions(text)
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func collapseSpaces(_ text: String) -> String {
        var output = ""
        var previousWasWhitespace = false

        for scalar in text.unicodeScalars {
            if CharacterSet.whitespaces.contains(scalar) {
                if !previousWasWhitespace {
                    output.append(" ")
                }
                previousWasWhitespace = true
            } else {
                output.append(String(scalar))
                previousWasWhitespace = false
            }
        }

        return output
    }

    private static func collapseLineBreaks(_ text: String) -> String {
        text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
    }

    private static func normalizePunctuationRuns(_ text: String) -> String {
        var out = text
        out = out.replacingOccurrences(of: #"!{2,}"#, with: "!", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\?{2,}"#, with: "?", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\.{4,}"#, with: "...", options: .regularExpression)
        out = out.replacingOccurrences(of: #",{2,}"#, with: ",", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\s+([,.;!?])"#, with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: #"([,.;!?])(\S)"#, with: "$1 $2", options: .regularExpression)
        return out
    }

    private static func dedupeImmediateRepeatedWords(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"\b([A-Za-z][A-Za-z'’\-]*)\s+\1\b"#,
            with: "$1",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    private static func capitalizeSentenceStarts(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var chars = Array(text)
        var shouldCapitalize = true

        for i in chars.indices {
            let c = chars[i]
            if shouldCapitalize, c.isLetter {
                chars[i] = Character(String(c).uppercased())
                shouldCapitalize = false
            }

            if c == "." || c == "!" || c == "?" || c == "\n" {
                shouldCapitalize = true
            }
        }

        return String(chars)
    }

    private static func normalizeCommonContractions(_ text: String) -> String {
        var out = text
        let replacements: [(String, String)] = [
            (#"\bi m\b"#, "I'm"),
            (#"\bdont\b"#, "don't"),
            (#"\bcant\b"#, "can't"),
            (#"\bwont\b"#, "won't")
        ]

        for (pattern, replacement) in replacements {
            out = out.replacingOccurrences(of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
        }

        return out
    }
}
