import Foundation

enum RecognitionTuning {
    static func clampedFinalizeDelay(_ value: TimeInterval) -> TimeInterval {
        min(1.2, max(0.15, value))
    }

    static func parseCustomPhrases(_ text: String) -> [String] {
        text
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func scoreTranscript(_ text: String) -> Int {
        let words = text.split { $0.isWhitespace || $0.isNewline }.count
        return words * 100 + text.count
    }

    static func chooseBetterTranscript(primary: String, fallback: String) -> String {
        let a = primary.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return scoreTranscript(a) >= scoreTranscript(b) ? a : b
    }

    static func contextualHints(defaults: [String], adaptive: [String] = [], custom: [String], limit: Int = 80) -> [String] {
        guard limit > 0 else { return [] }

        var seen = Set<String>()
        var ordered: [String] = []

        for phrase in adaptive + defaults + custom {
            let normalized = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }
            if seen.insert(normalized).inserted {
                ordered.append(normalized)
                if ordered.count == limit {
                    break
                }
            }
        }

        return ordered
    }

    static func whisperBiasPhrases(
        customContextPhrases: String,
        adaptiveBiasPhrases: [String],
        limit: Int = 48
    ) -> [String] {
        contextualHints(
            defaults: [],
            adaptive: adaptiveBiasPhrases,
            custom: parseCustomPhrases(customContextPhrases),
            limit: limit
        )
    }

    static func whisperInitialPrompt(from biasPhrases: [String], maxCharacters: Int = 320) -> String? {
        guard maxCharacters > 0 else { return nil }

        let prefix = "Use these exact terms when spoken: "
        let suffix = "."
        var usedLength = prefix.count + suffix.count
        var selected: [String] = []

        for rawPhrase in biasPhrases {
            let phrase = rawPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !phrase.isEmpty else { continue }

            let phraseCost = phrase.count + (selected.isEmpty ? 0 : 2)
            if usedLength + phraseCost > maxCharacters {
                break
            }

            selected.append(phrase)
            usedLength += phraseCost
        }

        guard !selected.isEmpty else { return nil }
        return prefix + selected.joined(separator: ", ") + suffix
    }
}
