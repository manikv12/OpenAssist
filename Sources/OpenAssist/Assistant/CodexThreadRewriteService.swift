import Foundation

enum CodexThreadRewriteError: LocalizedError {
    case sessionNotFound(String)
    case turnNotFound(String)
    case turnNotEditable(String)
    case editAlreadyPending(String)
    case noPendingEdit(String)

    var errorDescription: String? {
        switch self {
        case .sessionNotFound:
            return "Open Assist could not find that Codex thread on disk."
        case .turnNotFound:
            return "Open Assist could not find that message in the saved Codex thread."
        case .turnNotEditable:
            return "Only the latest user message can be edited right now."
        case .editAlreadyPending:
            return "Finish or cancel the current edit before starting another one."
        case .noPendingEdit:
            return "There is no pending edit to cancel."
        }
    }
}

struct CodexEditableAttachment: Equatable {
    let filename: String
    let data: Data
    let mimeType: String
}

struct CodexEditableTurn: Equatable {
    let sessionID: String
    let anchorID: String
    let text: String
    let createdAt: Date
    let imageAttachments: [CodexEditableAttachment]
    let supportsEdit: Bool
    let startLineIndex: Int
    let endLineIndex: Int
}

struct CodexRewriteBackup: Equatable {
    let sessionID: String
    let sessionFileURL: URL
    let backupFileURL: URL
    let createdAt: Date
}

struct CodexThreadRewriteOutcome: Equatable {
    let backup: CodexRewriteBackup
    let retainedTurns: [CodexEditableTurn]
    let removedTurns: [CodexEditableTurn]
    let editedTurn: CodexEditableTurn?
}

final class CodexThreadRewriteService {
    private enum AnchorKind: String {
        case responseMessage
        case eventMessage
    }

    private struct ParsedUserInput {
        let text: String?
        let timestamp: Date
        let imageAttachments: [CodexEditableAttachment]
        let hasUnsupportedAttachments: Bool
        let anchorKind: AnchorKind
        let lineIndex: Int
    }

    private struct ParsedTurnRecord {
        let turn: CodexEditableTurn
        let lines: [String]
    }

    private struct ParsedSession {
        let sessionFileURL: URL
        let preludeLines: [String]
        let turns: [ParsedTurnRecord]
    }

    private struct TurnAccumulator {
        let sessionID: String
        let startLineIndex: Int
        var endLineIndex: Int
        var createdAt: Date
        var rawLines: [String]
        var displayText: String
        var imageAttachments: [CodexEditableAttachment]
        var hasUnsupportedAttachments: Bool
        var preferredAnchorKind: AnchorKind
        var preferredAnchorLineIndex: Int
        var preferredAnchorTimestamp: Date
        var normalizedVisibleText: String?
        var sawNonUserInputLine = false

        mutating func append(
            line: String,
            lineIndex: Int,
            userInput: ParsedUserInput? = nil
        ) {
            rawLines.append(line)
            endLineIndex = lineIndex

            guard let userInput else {
                sawNonUserInputLine = true
                return
            }

            if let text = userInput.text?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty,
               displayText.isEmpty {
                displayText = text
            }

            mergeImageAttachments(userInput.imageAttachments)
            hasUnsupportedAttachments = hasUnsupportedAttachments || userInput.hasUnsupportedAttachments

            if preferredAnchorKind == .responseMessage, userInput.anchorKind == .eventMessage {
                preferredAnchorKind = .eventMessage
                preferredAnchorLineIndex = userInput.lineIndex
                preferredAnchorTimestamp = userInput.timestamp
            }
        }

        mutating func mergeImageAttachments(_ attachments: [CodexEditableAttachment]) {
            guard !attachments.isEmpty else { return }

            var existingKeys = Set(
                imageAttachments.map {
                    MemoryIdentifier.stableHexDigest(data: $0.data) + "|\($0.mimeType.lowercased())"
                }
            )

            for attachment in attachments {
                let key = MemoryIdentifier.stableHexDigest(data: attachment.data) + "|\(attachment.mimeType.lowercased())"
                guard existingKeys.insert(key).inserted else { continue }
                imageAttachments.append(attachment)
            }
        }

        func canMerge(with userInput: ParsedUserInput) -> Bool {
            guard !sawNonUserInputLine else { return false }
            guard userInput.lineIndex >= startLineIndex else { return false }
            let incomingText = CodexThreadRewriteService.normalizedVisibleText(userInput.text)

            switch (normalizedVisibleText, incomingText) {
            case let (lhs?, rhs?):
                return lhs == rhs
            case (nil, nil):
                return !imageAttachments.isEmpty || !userInput.imageAttachments.isEmpty
            default:
                return false
            }
        }

        func finalized() -> ParsedTurnRecord {
            let normalizedText = displayText.trimmingCharacters(in: .whitespacesAndNewlines)
            let seed = [
                sessionID,
                preferredAnchorKind.rawValue,
                String(preferredAnchorLineIndex),
                String(preferredAnchorTimestamp.timeIntervalSince1970),
                normalizedText
            ].joined(separator: "|")
            let anchorID = "turn-\(MemoryIdentifier.stableHexDigest(for: seed).prefix(24))"
            let attachments = imageAttachments

            return ParsedTurnRecord(
                turn: CodexEditableTurn(
                    sessionID: sessionID,
                    anchorID: anchorID,
                    text: normalizedText,
                    createdAt: createdAt,
                    imageAttachments: attachments,
                    supportsEdit: !hasUnsupportedAttachments,
                    startLineIndex: startLineIndex,
                    endLineIndex: endLineIndex
                ),
                lines: rawLines
            )
        }
    }

    private let fileManager: FileManager
    private let sessionCatalog: CodexSessionCatalog
    private let backupRootDirectoryURL: URL
    private var pendingEditBackupsBySessionID: [String: CodexRewriteBackup] = [:]
    private let fractionalSecondsDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let standardDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    init(
        fileManager: FileManager = .default,
        sessionCatalog: CodexSessionCatalog = CodexSessionCatalog(),
        backupRootDirectoryURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.sessionCatalog = sessionCatalog
        if let backupRootDirectoryURL {
            self.backupRootDirectoryURL = backupRootDirectoryURL
        } else {
            let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory())
                    .appendingPathComponent("Library/Application Support", isDirectory: true)
            self.backupRootDirectoryURL = applicationSupport
                .appendingPathComponent("OpenAssist", isDirectory: true)
                .appendingPathComponent("CodexThreadRewriteBackups", isDirectory: true)
        }
    }

    func editableTurns(sessionID: String) throws -> [CodexEditableTurn] {
        try parsedSession(sessionID: sessionID).turns.map(\.turn)
    }

    func truncateBeforeTurn(
        sessionID: String,
        turnAnchorID: String
    ) throws -> CodexThreadRewriteOutcome {
        let normalizedSessionID = normalizedSessionID(sessionID)
        let parsed = try parsedSession(sessionID: normalizedSessionID)
        guard let targetIndex = parsed.turns.firstIndex(where: { $0.turn.anchorID == turnAnchorID }) else {
            throw CodexThreadRewriteError.turnNotFound(turnAnchorID)
        }

        let backup = try createBackup(sessionID: normalizedSessionID, sessionFileURL: parsed.sessionFileURL)
        let retained = Array(parsed.turns.prefix(targetIndex))
        let removed = Array(parsed.turns.suffix(from: targetIndex))
        try writeSession(
            preludeLines: parsed.preludeLines,
            turnRecords: retained,
            to: parsed.sessionFileURL
        )

        return CodexThreadRewriteOutcome(
            backup: backup,
            retainedTurns: retained.map(\.turn),
            removedTurns: removed.map(\.turn),
            editedTurn: nil
        )
    }

    func beginEditLastTurn(
        sessionID: String,
        turnAnchorID: String
    ) throws -> CodexThreadRewriteOutcome {
        let normalizedSessionID = normalizedSessionID(sessionID)
        if pendingEditBackupsBySessionID[normalizedSessionID] != nil {
            throw CodexThreadRewriteError.editAlreadyPending(sessionID)
        }

        let parsed = try parsedSession(sessionID: normalizedSessionID)
        guard let targetIndex = parsed.turns.firstIndex(where: { $0.turn.anchorID == turnAnchorID }) else {
            throw CodexThreadRewriteError.turnNotFound(turnAnchorID)
        }
        guard targetIndex == parsed.turns.indices.last else {
            throw CodexThreadRewriteError.turnNotEditable(turnAnchorID)
        }

        let targetTurn = parsed.turns[targetIndex].turn
        guard targetTurn.supportsEdit else {
            throw CodexThreadRewriteError.turnNotEditable(turnAnchorID)
        }

        let backup = try createBackup(sessionID: normalizedSessionID, sessionFileURL: parsed.sessionFileURL)
        let retained = Array(parsed.turns.prefix(targetIndex))
        let removed = Array(parsed.turns.suffix(from: targetIndex))
        try writeSession(
            preludeLines: parsed.preludeLines,
            turnRecords: retained,
            to: parsed.sessionFileURL
        )
        pendingEditBackupsBySessionID[normalizedSessionID] = backup

        return CodexThreadRewriteOutcome(
            backup: backup,
            retainedTurns: retained.map(\.turn),
            removedTurns: removed.map(\.turn),
            editedTurn: targetTurn
        )
    }

    @discardableResult
    func cancelPendingEdit(sessionID: String) throws -> CodexRewriteBackup {
        let normalizedSessionID = normalizedSessionID(sessionID)
        guard let backup = pendingEditBackupsBySessionID.removeValue(forKey: normalizedSessionID) else {
            throw CodexThreadRewriteError.noPendingEdit(sessionID)
        }
        try restoreBackup(backup)
        return backup
    }

    func restoreBackup(_ backup: CodexRewriteBackup) throws {
        let data = try Data(contentsOf: backup.backupFileURL)
        try data.write(to: backup.sessionFileURL, options: .atomic)
    }

    func discardPendingEditBackup(sessionID: String) {
        let normalizedSessionID = normalizedSessionID(sessionID)
        if let backup = pendingEditBackupsBySessionID.removeValue(forKey: normalizedSessionID) {
            deleteBackup(backup)
        }
    }

    func deleteBackup(_ backup: CodexRewriteBackup) {
        try? fileManager.removeItem(at: backup.backupFileURL)
    }

    private func parsedSession(sessionID: String) throws -> ParsedSession {
        let normalizedSessionID = normalizedSessionID(sessionID)
        guard let sessionFileURL = sessionCatalog.sessionFileURL(for: normalizedSessionID),
              fileManager.fileExists(atPath: sessionFileURL.path) else {
            throw CodexThreadRewriteError.sessionNotFound(sessionID)
        }

        let contents = try String(contentsOf: sessionFileURL, encoding: .utf8)
        var lines = contents
            .split(maxSplits: Int.max, omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(String.init)
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }
        var preludeLines: [String] = []
        var turns: [ParsedTurnRecord] = []
        var currentTurn: TurnAccumulator?

        for (lineIndex, line) in lines.enumerated() {
            guard !line.isEmpty else {
                if currentTurn == nil {
                    preludeLines.append(line)
                } else {
                    currentTurn?.append(line: line, lineIndex: lineIndex)
                }
                continue
            }

            let json = jsonObject(from: line)
            let userInput = json.flatMap { visibleUserInput(from: $0, lineIndex: lineIndex) }

            if let userInput {
                if var existingTurn = currentTurn,
                   existingTurn.canMerge(with: userInput) {
                    existingTurn.append(line: line, lineIndex: lineIndex, userInput: userInput)
                    currentTurn = existingTurn
                    continue
                }

                if let finishedTurn = currentTurn?.finalized() {
                    turns.append(finishedTurn)
                }

                let normalizedText = Self.normalizedVisibleText(userInput.text)
                currentTurn = TurnAccumulator(
                    sessionID: normalizedSessionID,
                    startLineIndex: lineIndex,
                    endLineIndex: lineIndex,
                    createdAt: userInput.timestamp,
                    rawLines: [line],
                    displayText: userInput.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                    imageAttachments: userInput.imageAttachments,
                    hasUnsupportedAttachments: userInput.hasUnsupportedAttachments,
                    preferredAnchorKind: userInput.anchorKind,
                    preferredAnchorLineIndex: lineIndex,
                    preferredAnchorTimestamp: userInput.timestamp,
                    normalizedVisibleText: normalizedText
                )
            } else if var existingTurn = currentTurn {
                existingTurn.append(line: line, lineIndex: lineIndex)
                currentTurn = existingTurn
            } else {
                preludeLines.append(line)
            }
        }

        if let finishedTurn = currentTurn?.finalized() {
            turns.append(finishedTurn)
        }

        return ParsedSession(
            sessionFileURL: sessionFileURL,
            preludeLines: preludeLines,
            turns: turns
        )
    }

    private func createBackup(
        sessionID: String,
        sessionFileURL: URL
    ) throws -> CodexRewriteBackup {
        try fileManager.createDirectory(at: backupRootDirectoryURL, withIntermediateDirectories: true)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backupFileURL = backupRootDirectoryURL
            .appendingPathComponent("\(sessionID)-\(stamp).jsonl", isDirectory: false)

        let data = try Data(contentsOf: sessionFileURL)
        try data.write(to: backupFileURL, options: .atomic)
        return CodexRewriteBackup(
            sessionID: sessionID,
            sessionFileURL: sessionFileURL,
            backupFileURL: backupFileURL,
            createdAt: Date()
        )
    }

    private func writeSession(
        preludeLines: [String],
        turnRecords: [ParsedTurnRecord],
        to fileURL: URL
    ) throws {
        let rewrittenLines = preludeLines + turnRecords.flatMap(\.lines)
        let serialized = rewrittenLines.joined(separator: "\n") + "\n"
        try serialized.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func visibleUserInput(
        from json: [String: Any],
        lineIndex: Int
    ) -> ParsedUserInput? {
        let timestamp = parseDate(stringValue(json["timestamp"])) ?? Date()

        switch stringValue(json["type"])?.lowercased() {
        case "response_item":
            guard let payload = dictionaryValue(json["payload"]),
                  stringValue(payload["type"])?.lowercased() == "message",
                  stringValue(payload["role"])?.lowercased() == "user" else {
                return nil
            }

            let content = payload["content"]
            let text = cleanedUserMessage(extractMessageText(from: content))
            let images = extractAttachments(from: content)
            guard text != nil || !images.attachments.isEmpty || images.hasUnsupportedAttachments else {
                return nil
            }

            return ParsedUserInput(
                text: text,
                timestamp: timestamp,
                imageAttachments: images.attachments,
                hasUnsupportedAttachments: images.hasUnsupportedAttachments,
                anchorKind: .responseMessage,
                lineIndex: lineIndex
            )

        case "event_msg":
            guard let payload = dictionaryValue(json["payload"]),
                  stringValue(payload["type"])?.lowercased() == "user_message" else {
                return nil
            }

            let text = cleanedUserMessage(stringValue(payload["message"]))
            let images = extractAttachments(from: payload["images"])
            guard text != nil || !images.attachments.isEmpty else {
                return nil
            }

            return ParsedUserInput(
                text: text,
                timestamp: timestamp,
                imageAttachments: images.attachments,
                hasUnsupportedAttachments: false,
                anchorKind: .eventMessage,
                lineIndex: lineIndex
            )

        default:
            return nil
        }
    }

    private func extractAttachments(from rawValue: Any?) -> (attachments: [CodexEditableAttachment], hasUnsupportedAttachments: Bool) {
        var attachments: [CodexEditableAttachment] = []
        var existingKeys: Set<String> = []
        var hasUnsupportedAttachments = false

        collectAttachments(
            from: rawValue,
            into: &attachments,
            existingKeys: &existingKeys,
            hasUnsupportedAttachments: &hasUnsupportedAttachments
        )

        return (attachments, hasUnsupportedAttachments)
    }

    private func collectAttachments(
        from rawValue: Any?,
        into attachments: inout [CodexEditableAttachment],
        existingKeys: inout Set<String>,
        hasUnsupportedAttachments: inout Bool
    ) {
        switch rawValue {
        case let array as [Any]:
            for item in array {
                collectAttachments(
                    from: item,
                    into: &attachments,
                    existingKeys: &existingKeys,
                    hasUnsupportedAttachments: &hasUnsupportedAttachments
                )
            }

        case let dictionary as [String: Any]:
            let type = stringValue(dictionary["type"])?.lowercased()

            if let attachment = attachment(from: dictionary) {
                let key = MemoryIdentifier.stableHexDigest(data: attachment.data) + "|\(attachment.mimeType.lowercased())"
                if existingKeys.insert(key).inserted {
                    attachments.append(attachment)
                }
            } else if isUnsupportedAttachmentType(type) {
                hasUnsupportedAttachments = true
            }

            if let imageURL = dictionary["image_url"] {
                collectAttachments(
                    from: imageURL,
                    into: &attachments,
                    existingKeys: &existingKeys,
                    hasUnsupportedAttachments: &hasUnsupportedAttachments
                )
            }
            if let url = dictionary["url"] {
                collectAttachments(
                    from: url,
                    into: &attachments,
                    existingKeys: &existingKeys,
                    hasUnsupportedAttachments: &hasUnsupportedAttachments
                )
            }
            if let content = dictionary["content"] {
                collectAttachments(
                    from: content,
                    into: &attachments,
                    existingKeys: &existingKeys,
                    hasUnsupportedAttachments: &hasUnsupportedAttachments
                )
            }
            if let images = dictionary["images"] {
                collectAttachments(
                    from: images,
                    into: &attachments,
                    existingKeys: &existingKeys,
                    hasUnsupportedAttachments: &hasUnsupportedAttachments
                )
            }

        case let string as String:
            if let attachment = attachment(fromDataURL: string) {
                let key = MemoryIdentifier.stableHexDigest(data: attachment.data) + "|\(attachment.mimeType.lowercased())"
                if existingKeys.insert(key).inserted {
                    attachments.append(attachment)
                }
            }

        default:
            break
        }
    }

    private func attachment(from dictionary: [String: Any]) -> CodexEditableAttachment? {
        if let imageURL = stringValue(dictionary["image_url"]),
           let attachment = attachment(fromDataURL: imageURL) {
            return attachment
        }
        if let imageURL = dictionaryValue(dictionary["image_url"]),
           let url = stringValue(imageURL["url"]),
           let attachment = attachment(fromDataURL: url) {
            return attachment
        }
        if let url = stringValue(dictionary["url"]),
           let attachment = attachment(fromDataURL: url) {
            return attachment
        }
        return nil
    }

    private func attachment(fromDataURL rawValue: String) -> CodexEditableAttachment? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:"),
              let commaIndex = trimmed.firstIndex(of: ",") else {
            return nil
        }

        let metadata = String(trimmed[..<commaIndex])
        let payload = String(trimmed[trimmed.index(after: commaIndex)...])
        guard metadata.contains(";base64"),
              let data = Data(base64Encoded: payload) else {
            return nil
        }

        let mimeType = String(metadata.dropFirst(5).split(separator: ";").first ?? "image/png")
        guard mimeType.lowercased().hasPrefix("image/") else { return nil }
        let fileExtension = mimeTypeToExtension(mimeType)
        return CodexEditableAttachment(
            filename: "edited-image-\(attachmentsafeDigest(data)).\(fileExtension)",
            data: data,
            mimeType: mimeType
        )
    }

    private func attachmentsafeDigest(_ data: Data) -> String {
        String(MemoryIdentifier.stableHexDigest(data: data).prefix(12))
    }

    private func mimeTypeToExtension(_ mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "image/png":
            return "png"
        case "image/jpeg", "image/jpg":
            return "jpg"
        case "image/gif":
            return "gif"
        case "image/webp":
            return "webp"
        case "image/tiff":
            return "tiff"
        case "image/heic":
            return "heic"
        default:
            return "png"
        }
    }

    private func isUnsupportedAttachmentType(_ rawType: String?) -> Bool {
        guard let rawType else { return false }
        let normalized = rawType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty {
            return false
        }

        let supportedTypes: Set<String> = [
            "input_text",
            "output_text",
            "text",
            "image",
            "input_image",
            "image_url"
        ]
        let explicitlyIgnoredTypes: Set<String> = [
            "message"
        ]

        if supportedTypes.contains(normalized) || explicitlyIgnoredTypes.contains(normalized) {
            return false
        }

        return normalized.contains("file") || normalized.contains("attachment")
    }

    private static func normalizedVisibleText(_ rawValue: String?) -> String? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }

        return rawValue
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            .lowercased()
    }

    private func cleanedUserMessage(_ rawValue: String?) -> String? {
        guard var text = normalizeTranscriptMessage(rawValue) else {
            return nil
        }

        if text.contains("## My request for Codex:"),
           let extracted = extractSuffix(after: "## My request for Codex:", in: text) {
            text = extracted
        } else if let extracted = extractSuffix(after: "My request for Codex:", in: text) {
            text = extracted
        } else if let extracted = extractSuffix(after: "User prompt:", in: text) {
            text = extracted
        }

        if text.hasPrefix("<environment_context>") || text.hasPrefix("<permissions instructions>") {
            return nil
        }

        if text.hasPrefix("# AGENTS.md instructions") {
            return nil
        }

        if text.hasPrefix("# Session Memory") {
            return nil
        }

        if text.hasPrefix("<turn_aborted>") ||
            text.hasPrefix("<skill>") ||
            text.hasPrefix("# Recovered Thread Context") ||
            text.hasPrefix("# Context from my IDE setup:") ||
            text.hasPrefix("# Files mentioned by the user:") {
            return nil
        }

        if text.contains("## Available skills") && text.count > 400 {
            return nil
        }

        if text.hasPrefix("You are ") && text.count > 400 {
            return nil
        }

        return normalizeTranscriptMessage(text)
    }

    private func extractMessageText(from rawValue: Any?) -> String? {
        var fragments: [String] = []
        collectTextFragments(from: rawValue, into: &fragments)

        guard !fragments.isEmpty else {
            return nil
        }

        var uniqueFragments: [String] = []
        var seen = Set<String>()
        for fragment in fragments {
            let normalized = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else {
                continue
            }
            if normalized.hasPrefix("# Session Memory") {
                continue
            }
            uniqueFragments.append(normalized)
        }

        return normalizeTranscriptMessage(uniqueFragments.joined(separator: "\n\n"))
    }

    private func collectTextFragments(from rawValue: Any?, into fragments: inout [String]) {
        switch rawValue {
        case let string as String:
            fragments.append(string)
        case let array as [Any]:
            for item in array {
                collectTextFragments(from: item, into: &fragments)
            }
        case let dictionary as [String: Any]:
            if let text = stringValue(dictionary["text"]) {
                fragments.append(text)
            }
            if let message = stringValue(dictionary["message"]) {
                fragments.append(message)
            }
            if let content = dictionary["content"] {
                collectTextFragments(from: content, into: &fragments)
            }
            if let summary = dictionary["summary"] {
                collectTextFragments(from: summary, into: &fragments)
            }
        default:
            break
        }
    }

    private func extractSuffix(after marker: String, in value: String) -> String? {
        guard let range = value.range(of: marker, options: [.caseInsensitive, .backwards]) else {
            return nil
        }
        return value[range.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
    }

    private func normalizeTranscriptMessage(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let normalized = sanitizeAttachmentPlaceholders(in: value)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private func sanitizeAttachmentPlaceholders(in value: String) -> String {
        value
            .replacingOccurrences(
                of: #"<image>\s*</image>"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"</?image>"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"</?input_image>"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"[^\S\n]+"#,
                with: " ",
                options: .regularExpression
            )
    }

    private func normalizedSessionID(_ sessionID: String) -> String {
        sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseDate(_ raw: String?) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }

        if let value = fractionalSecondsDateFormatter.date(from: raw) {
            return value
        }
        return standardDateFormatter.date(from: raw)
    }

    private func jsonObject(from rawLine: String) -> [String: Any]? {
        guard let data = rawLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private func dictionaryValue(_ rawValue: Any?) -> [String: Any]? {
        rawValue as? [String: Any]
    }

    private func stringValue(_ rawValue: Any?) -> String? {
        rawValue as? String
    }
}
