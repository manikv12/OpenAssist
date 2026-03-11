import Foundation

@MainActor
final class AdaptiveCorrectionStore: ObservableObject {
    struct LearnedCorrection: Codable, Identifiable, Hashable {
        let source: String
        var replacement: String
        var learnCount: Int
        var updatedAt: Date

        var id: String { source }

        var sourceTokenCount: Int {
            source.split(separator: " ").count
        }

        var sourceTokens: [String] {
            source.split(separator: " ").map(String.init)
        }
    }

    struct LearningEvent: Equatable {
        let source: String
        let replacement: String
        let learnCount: Int
    }

    struct AppliedEvent: Equatable {
        let source: String
        let replacement: String
    }

    struct ApplyResult: Equatable {
        let text: String
        let appliedEvents: [AppliedEvent]
    }

    private struct ApplyMatcher {
        let source: String
        let sourceTokens: [String]
        let replacement: String
        let learnCount: Int
        let minimumLearnCountToApply: Int
    }

    static let shared = AdaptiveCorrectionStore()

    @Published private(set) var learnedCorrections: [LearnedCorrection] = [] {
        didSet {
            applyMatcherIndexNeedsRebuild = true
        }
    }

    private let defaults = UserDefaults.standard
    private static let legacyStorageKey = "OpenAssist.learnedCorrections.v1"
    private static let storageFileName = "learned-corrections.json"
    private static let fallbackStoragePath = "\(NSHomeDirectory())/Library/Application Support/OpenAssist/Models/\(storageFileName)"

    private struct WordToken {
        let original: String
        let normalized: String
        let range: Range<String.Index>
    }

    private static let wordRegex = try? NSRegularExpression(
        pattern: "[A-Za-z0-9]+(?:[._'/-][A-Za-z0-9]+)*",
        options: []
    )
    private static let ambiguousMergeFunctionWords: Set<String> = [
        "a", "an", "and", "as", "at", "by", "for", "from", "if", "in", "of", "on", "or", "the", "to", "with"
    ]

    private let persistenceEnabled: Bool
    private var applyMatcherIndexByFirstToken: [String: [ApplyMatcher]] = [:]
    private var applyMatcherIndexNeedsRebuild = true

    private init(
        loadPersistedCorrections: Bool = true,
        persistenceEnabled: Bool = true,
        seedCorrections: [LearnedCorrection] = []
    ) {
        self.persistenceEnabled = persistenceEnabled
        if loadPersistedCorrections {
            load()
        } else {
            learnedCorrections = seedCorrections
        }
    }

    static func inMemoryStoreForSmokeTests(seedCorrections: [LearnedCorrection] = []) -> AdaptiveCorrectionStore {
        AdaptiveCorrectionStore(
            loadPersistedCorrections: false,
            persistenceEnabled: false,
            seedCorrections: seedCorrections
        )
    }

    func apply(to text: String) -> String {
        applyWithEvents(to: text).text
    }

    func applyWithEvents(to text: String) -> ApplyResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ApplyResult(text: text, appliedEvents: []) }
        guard !learnedCorrections.isEmpty else { return ApplyResult(text: text, appliedEvents: []) }

        let tokens = tokenize(text)
        guard !tokens.isEmpty else { return ApplyResult(text: text, appliedEvents: []) }

        ensureApplyMatcherIndex()

        struct PendingReplacement {
            let range: Range<String.Index>
            let text: String
            let event: AppliedEvent
        }

        var replacements: [PendingReplacement] = []
        var index = 0

        while index < tokens.count {
            let currentNormalized = tokens[index].normalized
            guard let candidates = applyMatcherIndexByFirstToken[currentNormalized], !candidates.isEmpty else {
                index += 1
                continue
            }

            var matchedCorrection: ApplyMatcher?
            for candidate in candidates {
                guard candidate.learnCount >= candidate.minimumLearnCountToApply else { continue }
                let sourceTokens = candidate.sourceTokens
                guard index + sourceTokens.count <= tokens.count else { continue }

                var isMatch = true
                for offset in 0..<sourceTokens.count {
                    if tokens[index + offset].normalized != sourceTokens[offset] {
                        isMatch = false
                        break
                    }
                }

                if isMatch {
                    matchedCorrection = candidate
                    break
                }
            }

            if let correction = matchedCorrection {
                let matchedLength = correction.sourceTokens.count
                let start = tokens[index].range.lowerBound
                let end = tokens[index + matchedLength - 1].range.upperBound
                let replacement = adaptReplacementCase(
                    replacement: correction.replacement,
                    sourceToken: tokens[index].original
                )
                replacements.append(
                    PendingReplacement(
                        range: start..<end,
                        text: replacement,
                        event: AppliedEvent(source: correction.source, replacement: correction.replacement)
                    )
                )
                index += matchedLength
            } else {
                index += 1
            }
        }

        guard !replacements.isEmpty else { return ApplyResult(text: text, appliedEvents: []) }

        var updated = text
        for replacement in replacements.reversed() {
            updated.replaceSubrange(replacement.range, with: replacement.text)
        }
        return ApplyResult(
            text: updated,
            appliedEvents: replacements.map(\.event)
        )
    }

    func preferredRecognitionPhrases(limit: Int = 40) -> [String] {
        guard limit > 0 else { return [] }
        guard !learnedCorrections.isEmpty else { return [] }

        let prioritized = learnedCorrections.sorted {
            if $0.learnCount != $1.learnCount {
                return $0.learnCount > $1.learnCount
            }
            return $0.updatedAt > $1.updatedAt
        }

        var seen = Set<String>()
        var phrases: [String] = []
        phrases.reserveCapacity(min(limit, prioritized.count))

        for correction in prioritized {
            let replacement = correction.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !replacement.isEmpty else { continue }

            let normalized = replacement.lowercased()
            if seen.insert(normalized).inserted {
                phrases.append(replacement)
                if phrases.count == limit {
                    break
                }
            }
        }

        return phrases
    }

    func proposedLearningEvent(from originalText: String, correctedText: String, insertionHint: String? = nil) -> LearningEvent? {
        guard let candidate = extractCandidate(from: originalText, to: correctedText) else {
            return nil
        }

        guard shouldLearnCandidate(source: candidate.source, replacement: candidate.replacement, insertionHint: insertionHint) else {
            return nil
        }

        if let existing = learnedCorrections.first(where: { $0.source == candidate.source }) {
            return LearningEvent(
                source: existing.source,
                replacement: candidate.replacement,
                learnCount: max(1, existing.learnCount + 1)
            )
        }

        return LearningEvent(source: candidate.source, replacement: candidate.replacement, learnCount: 1)
    }

    func learn(from originalText: String, correctedText: String, insertionHint: String? = nil) -> [LearningEvent] {
        guard let proposed = proposedLearningEvent(
            from: originalText,
            correctedText: correctedText,
            insertionHint: insertionHint
        ) else {
            return []
        }

        guard let saved = acceptProposedLearning(source: proposed.source, replacement: proposed.replacement) else {
            return []
        }

        return [saved]
    }

    @discardableResult
    func acceptProposedLearning(source rawSource: String, replacement rawReplacement: String) -> LearningEvent? {
        commitLearnedCorrection(source: rawSource, replacement: rawReplacement)
    }

    @discardableResult
    func upsertManualCorrection(source rawSource: String, replacement rawReplacement: String) -> LearnedCorrection? {
        let source = normalizedSourceKey(from: rawSource)
        let replacement = rawReplacement.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !source.isEmpty, !replacement.isEmpty else { return nil }
        guard source.count >= 2, replacement.count >= 2 else { return nil }

        if let existingIndex = learnedCorrections.firstIndex(where: { $0.source == source }) {
            var existing = learnedCorrections[existingIndex]
            existing.replacement = replacement
            existing.updatedAt = Date()
            if existing.learnCount < 2 {
                existing.learnCount = 2
            }
            learnedCorrections[existingIndex] = existing
            persist()
            return existing
        }

        let created = LearnedCorrection(
            source: source,
            replacement: replacement,
            learnCount: 2,
            updatedAt: Date()
        )
        learnedCorrections.insert(created, at: 0)
        persist()
        return created
    }

    func removeCorrection(source: String) {
        guard let index = learnedCorrections.firstIndex(where: { $0.source == source }) else { return }
        learnedCorrections.remove(at: index)
        persist()
    }

    func clearAll() {
        guard !learnedCorrections.isEmpty else { return }
        learnedCorrections.removeAll()
        persist()
    }

    private func shouldLearnCandidate(source: String, replacement: String, insertionHint: String?) -> Bool {
        let sourceTokenList = source.split(separator: " ").map(String.init)
        let replacementTokenList = tokenize(replacement).map(\.normalized)

        if let insertionHint, !insertionHint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let hintTokens = Set(tokenize(insertionHint).map(\.normalized))
            let sourceTokens = Set(sourceTokenList)
            if !hintTokens.isEmpty && sourceTokens.isDisjoint(with: hintTokens) {
                // Keep the unrelated-edit guard for broad rewrites, but allow focused 1-2 word fixes.
                if sourceTokenList.count > 2 || replacementTokenList.count > 3 {
                    return false
                }
            }
        }

        return true
    }

    private func minimumLearnCountForAutoApply(sourceTokens: [String], replacement: String) -> Int {
        isAmbiguousConcatenationMerge(sourceTokens: sourceTokens, replacement: replacement) ? 2 : 1
    }

    private func isAmbiguousConcatenationMerge(sourceTokens: [String], replacement: String) -> Bool {
        guard sourceTokens.count >= 2 else { return false }
        let replacementTokens = tokenize(replacement).map(\.normalized)
        guard replacementTokens.count == 1 else { return false }
        guard editDistanceAtMostOne(sourceTokens.joined(), replacementTokens[0]) else { return false }
        return sourceTokens.contains { Self.ambiguousMergeFunctionWords.contains($0) }
    }

    private func editDistanceAtMostOne(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }

        let left = Array(lhs)
        let right = Array(rhs)
        let countDelta = left.count - right.count
        if abs(countDelta) > 1 { return false }

        if countDelta == 0 {
            var mismatches = 0
            for index in left.indices where left[index] != right[index] {
                mismatches += 1
                if mismatches > 1 {
                    return false
                }
            }
            return true
        }

        if countDelta > 0 {
            return canAlignBySkippingSingleCharacter(longer: left, shorter: right)
        }

        return canAlignBySkippingSingleCharacter(longer: right, shorter: left)
    }

    private func canAlignBySkippingSingleCharacter(longer: [Character], shorter: [Character]) -> Bool {
        var longIndex = 0
        var shortIndex = 0
        var skipped = false

        while longIndex < longer.count, shortIndex < shorter.count {
            if longer[longIndex] == shorter[shortIndex] {
                longIndex += 1
                shortIndex += 1
                continue
            }

            if skipped {
                return false
            }

            skipped = true
            longIndex += 1
        }

        return true
    }

    private func ensureApplyMatcherIndex() {
        guard applyMatcherIndexNeedsRebuild else { return }
        applyMatcherIndexNeedsRebuild = false

        guard !learnedCorrections.isEmpty else {
            applyMatcherIndexByFirstToken = [:]
            return
        }

        let sortedCorrections = learnedCorrections.sorted {
            if $0.sourceTokenCount != $1.sourceTokenCount {
                return $0.sourceTokenCount > $1.sourceTokenCount
            }
            if $0.learnCount != $1.learnCount {
                return $0.learnCount > $1.learnCount
            }
            return $0.updatedAt > $1.updatedAt
        }

        var index: [String: [ApplyMatcher]] = [:]
        index.reserveCapacity(sortedCorrections.count)

        for correction in sortedCorrections {
            let sourceTokens = correction.sourceTokens
            guard let firstToken = sourceTokens.first else { continue }
            let minimumLearnCountToApply = minimumLearnCountForAutoApply(
                sourceTokens: sourceTokens,
                replacement: correction.replacement
            )
            index[firstToken, default: []].append(
                ApplyMatcher(
                    source: correction.source,
                    sourceTokens: sourceTokens,
                    replacement: correction.replacement,
                    learnCount: correction.learnCount,
                    minimumLearnCountToApply: minimumLearnCountToApply
                )
            )
        }

        applyMatcherIndexByFirstToken = index
    }

    private func commitLearnedCorrection(source rawSource: String, replacement rawReplacement: String) -> LearningEvent? {
        let source = normalizedSourceKey(from: rawSource)
        let replacement = rawReplacement.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !source.isEmpty, !replacement.isEmpty else { return nil }
        guard source.count >= 2, replacement.count >= 2 else { return nil }

        if let existingIndex = learnedCorrections.firstIndex(where: { $0.source == source }) {
            var existing = learnedCorrections[existingIndex]
            existing.replacement = replacement
            existing.learnCount = max(1, existing.learnCount + 1)
            existing.updatedAt = Date()
            learnedCorrections[existingIndex] = existing

            learnedCorrections.sort {
                if $0.learnCount != $1.learnCount {
                    return $0.learnCount > $1.learnCount
                }
                return $0.updatedAt > $1.updatedAt
            }

            persist()
            return LearningEvent(source: existing.source, replacement: existing.replacement, learnCount: existing.learnCount)
        }

        let created = LearnedCorrection(
            source: source,
            replacement: replacement,
            learnCount: 1,
            updatedAt: Date()
        )
        learnedCorrections.insert(created, at: 0)
        persist()
        return LearningEvent(source: created.source, replacement: created.replacement, learnCount: created.learnCount)
    }

    private func persist() {
        guard persistenceEnabled else { return }

        if learnedCorrections.isEmpty {
            if let fileURL = Self.storageFileURL() {
                try? FileManager.default.removeItem(at: fileURL)
            }
            defaults.removeObject(forKey: Self.legacyStorageKey)
            return
        }

        guard let data = try? JSONEncoder().encode(learnedCorrections) else {
            return
        }
        guard let fileURL = Self.storageFileURL() else {
            return
        }
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            return
        }
    }

    private func load() {
        if let fileURL = Self.storageFileURL(),
           let fileData = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([LearnedCorrection].self, from: fileData) {
            learnedCorrections = decoded.filter { correction in
                !correction.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                    !correction.replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            if !learnedCorrections.isEmpty {
                return
            }
        } else if let legacyData = defaults.data(forKey: Self.legacyStorageKey),
                  let decoded = try? JSONDecoder().decode([LearnedCorrection].self, from: legacyData) {
            learnedCorrections = decoded.filter { correction in
                !correction.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                    !correction.replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            persist()
            defaults.removeObject(forKey: Self.legacyStorageKey)
            return
        }

        learnedCorrections = []
    }

    private func extractCandidate(from originalText: String, to correctedText: String) -> (source: String, replacement: String)? {
        let oldTokens = tokenize(originalText)
        let newTokens = tokenize(correctedText)

        guard !oldTokens.isEmpty, !newTokens.isEmpty else { return nil }

        var prefixCount = 0
        while prefixCount < oldTokens.count,
              prefixCount < newTokens.count,
              oldTokens[prefixCount].normalized == newTokens[prefixCount].normalized {
            prefixCount += 1
        }

        var oldSuffixStart = oldTokens.count
        var newSuffixStart = newTokens.count

        while oldSuffixStart > prefixCount,
              newSuffixStart > prefixCount,
              oldTokens[oldSuffixStart - 1].normalized == newTokens[newSuffixStart - 1].normalized {
            oldSuffixStart -= 1
            newSuffixStart -= 1
        }

        let oldChanged = Array(oldTokens[prefixCount..<oldSuffixStart])
        let newChanged = Array(newTokens[prefixCount..<newSuffixStart])

        guard !oldChanged.isEmpty, !newChanged.isEmpty else { return nil }

        // Avoid learning from broad sentence rewrites or full clears.
        if prefixCount == 0,
           oldSuffixStart == oldTokens.count,
           newSuffixStart == newTokens.count,
           max(oldTokens.count, newTokens.count) > 6 {
            return nil
        }

        guard oldChanged.count <= 4, newChanged.count <= 5 else {
            return nil
        }

        let source = oldChanged.map(\.normalized).joined(separator: " ")
        let replacement = newChanged.map(\.original).joined(separator: " ")

        let normalizedReplacement = newChanged.map(\.normalized).joined(separator: " ")

        guard source != normalizedReplacement else { return nil }
        guard source.count >= 2, replacement.count >= 2 else { return nil }

        return (source: source, replacement: replacement)
    }

    private func tokenize(_ text: String) -> [WordToken] {
        guard let regex = Self.wordRegex else { return [] }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: range)

        return matches.compactMap { match in
            guard let tokenRange = Range(match.range, in: text) else {
                return nil
            }

            let value = String(text[tokenRange])
            let normalized = value.lowercased()
            return WordToken(original: value, normalized: normalized, range: tokenRange)
        }
    }

    private func normalizedSourceKey(from text: String) -> String {
        tokenize(text).map(\.normalized).joined(separator: " ")
    }

    private func adaptReplacementCase(replacement: String, sourceToken: String) -> String {
        guard let firstSource = sourceToken.first else { return replacement }
        guard let firstReplacement = replacement.first else { return replacement }

        if sourceToken == sourceToken.uppercased() {
            return replacement.uppercased()
        }

        if firstSource.isUppercase, firstReplacement.isLowercase {
            return firstReplacement.uppercased() + replacement.dropFirst()
        }

        return replacement
    }

    static func storageFilePath() -> String {
        fallbackStoragePath
    }

    private static func storageFileURL() -> URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupport
            .appendingPathComponent("OpenAssist", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(storageFileName)
    }
}
