import Foundation

enum AssistantTimelineDetailSanitizer {
    static let defaultLimit = 4_000

    private static let imageDataPlaceholder = "[image data omitted]"
    private static let imageBase64Prefixes = [
        "iVBOR",
        "/9j/",
        "R0lGOD",
        "UklGR"
    ]

    static func sanitized(_ rawValue: String?, limit: Int = defaultLimit) -> String? {
        guard var text = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return nil
        }

        text = replacingDataImageURLs(in: text)
        text = replacingLikelyImageBase64Tokens(in: text)

        if text.count > limit {
            text = String(text.prefix(max(0, limit - 3))) + "..."
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    static func isOnlyOmittedImageData(_ value: String?) -> Bool {
        guard let sanitized = sanitized(value) else { return false }
        let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == imageDataPlaceholder
            || trimmed == "\"\(imageDataPlaceholder)\""
            || trimmed == "'\(imageDataPlaceholder)'"
    }

    private static func replacingDataImageURLs(in text: String) -> String {
        var result = ""
        var cursor = text.startIndex

        while let range = text.range(
            of: "data:image/",
            options: [.caseInsensitive],
            range: cursor..<text.endIndex
        ) {
            result.append(contentsOf: text[cursor..<range.lowerBound])

            var end = range.lowerBound
            while end < text.endIndex, !isDataURLDelimiter(text[end]) {
                end = text.index(after: end)
            }

            result.append(contentsOf: imageDataPlaceholder)
            cursor = end
        }

        result.append(contentsOf: text[cursor..<text.endIndex])
        return result
    }

    private static func replacingLikelyImageBase64Tokens(in text: String) -> String {
        var text = text
        for prefix in imageBase64Prefixes {
            text = replacingBase64Tokens(in: text, matchingPrefix: prefix)
        }
        return text
    }

    private static func replacingBase64Tokens(
        in text: String,
        matchingPrefix prefix: String
    ) -> String {
        var result = ""
        var cursor = text.startIndex

        while let range = text.range(of: prefix, range: cursor..<text.endIndex) {
            var tokenStart = range.lowerBound
            while tokenStart > cursor {
                let previous = text.index(before: tokenStart)
                guard isBase64Character(text[previous]) else { break }
                tokenStart = previous
            }

            var tokenEnd = range.upperBound
            while tokenEnd < text.endIndex, isBase64Character(text[tokenEnd]) {
                tokenEnd = text.index(after: tokenEnd)
            }

            let tokenLength = text.distance(from: tokenStart, to: tokenEnd)
            guard tokenLength >= 256 else {
                result.append(contentsOf: text[cursor..<range.upperBound])
                cursor = range.upperBound
                continue
            }

            result.append(contentsOf: text[cursor..<tokenStart])
            result.append(contentsOf: imageDataPlaceholder)
            cursor = tokenEnd
        }

        result.append(contentsOf: text[cursor..<text.endIndex])
        return result
    }

    private static func isBase64Character(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first else {
            return false
        }

        switch scalar.value {
        case 48...57, 65...90, 97...122:
            return true
        case 43, 47, 61:
            return true
        default:
            return false
        }
    }

    private static func isDataURLDelimiter(_ character: Character) -> Bool {
        if character.isWhitespace || character.isNewline {
            return true
        }

        switch character {
        case "\"", "'", "<", ">", ")", "]", "}":
            return true
        default:
            return false
        }
    }
}
