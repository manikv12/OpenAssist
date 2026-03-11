import Foundation
import SQLite3

protocol MemorySourceAdapter {
    var provider: MemoryProviderKind { get }
    var maxFileSizeBytes: Int64 { get }
    var allowedFileExtensions: Set<String> { get }

    func discoverFiles(
        in rootURL: URL,
        fileManager: FileManager,
        maxFiles: Int
    ) -> [URL]

    func parse(
        fileURL: URL,
        relativePath: String,
        fileManager: FileManager
    ) throws -> [MemoryEventDraft]
}

enum MemorySourceAdapterError: LocalizedError {
    case unreadableData(path: String)
    case unsupportedFormat(path: String)

    var errorDescription: String? {
        switch self {
        case let .unreadableData(path):
            return "Unreadable source data at path: \(path)"
        case let .unsupportedFormat(path):
            return "Unsupported source format at path: \(path)"
        }
    }
}

struct MemorySourceAdapterRegistry {
    let adaptersByProvider: [MemoryProviderKind: any MemorySourceAdapter]

    init(adapters: [any MemorySourceAdapter] = MemorySourceAdapterRegistry.defaultAdapters()) {
        var dictionary: [MemoryProviderKind: any MemorySourceAdapter] = [:]
        dictionary.reserveCapacity(adapters.count)
        for adapter in adapters {
            dictionary[adapter.provider] = adapter
        }
        adaptersByProvider = dictionary
    }

    func adapter(for provider: MemoryProviderKind) -> (any MemorySourceAdapter)? {
        adaptersByProvider[provider]
    }

    static func defaultAdapters() -> [any MemorySourceAdapter] {
        [
            CodexMemorySourceAdapter(),
            OpenCodeMemorySourceAdapter(),
            ClaudeMemorySourceAdapter(),
            CopilotMemorySourceAdapter(),
            CursorMemorySourceAdapter(),
            KimiMemorySourceAdapter(),
            GeminiMemorySourceAdapter(),
            WindsurfMemorySourceAdapter(),
            CodeiumMemorySourceAdapter()
        ]
    }
}

private enum MemoryAdapterFileDiscovery {
    private static let parseableFilenameNeedles: [String] = [
        "conversation", "conversations", "chat", "history", "session", "prompt",
        "rewrite", "transcript", "memory", "messages"
    ]

    static func discoverFiles(
        in rootURL: URL,
        fileManager: FileManager,
        allowedFileExtensions: Set<String>,
        maxFileSizeBytes: Int64,
        maxFiles: Int
    ) -> [URL] {
        guard maxFiles > 0 else { return [] }
        let resourceKeys: [URLResourceKey] = [
            .isRegularFileKey,
            .isDirectoryKey,
            .fileSizeKey,
            .nameKey
        ]
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return []
        }

        var files: [URL] = []
        files.reserveCapacity(min(maxFiles, 256))

        for case let fileURL as URL in enumerator {
            if files.count >= maxFiles {
                break
            }
            guard let values = try? fileURL.resourceValues(forKeys: Set(resourceKeys)) else { continue }

            if values.isDirectory == true {
                let directoryName = (values.name ?? fileURL.lastPathComponent).lowercased()
                if shouldSkipDirectory(named: directoryName) {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard values.isRegularFile == true else { continue }

            let ext = fileURL.pathExtension.lowercased()
            let fileName = (values.name ?? fileURL.lastPathComponent).lowercased()
            if !shouldIncludeFile(
                named: fileName,
                extension: ext,
                allowedFileExtensions: allowedFileExtensions
            ) {
                continue
            }

            if let size = values.fileSize, Int64(size) > maxFileSizeBytes {
                continue
            }

            files.append(fileURL.standardizedFileURL)
        }

        return files.sorted { lhs, rhs in
            lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
        }
    }

    private static func shouldSkipDirectory(named directoryName: String) -> Bool {
        switch directoryName {
        case ".git", "node_modules", "cache", "caches", "tmp", "temp", "gpucache", "code cache", "blob_storage":
            return true
        default:
            return false
        }
    }

    private static func shouldIncludeFile(
        named fileName: String,
        extension fileExtension: String,
        allowedFileExtensions: Set<String>
    ) -> Bool {
        guard !allowedFileExtensions.isEmpty else { return true }

        if !fileExtension.isEmpty {
            return allowedFileExtensions.contains(fileExtension)
        }

        return parseableFilenameNeedles.contains { needle in
            fileName.contains(needle)
        }
    }
}

private enum MemoryAdapterEventParser {
    private struct ConversationTurnCandidate {
        let role: String
        let body: String
        let timestamp: Date
        let metadata: [String: String]
        let isSummaryOnly: Bool
    }

    private static let fractionalISO8601Parser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainISO8601Parser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let sqliteTransientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func parseFile(
        provider: MemoryProviderKind,
        fileURL: URL,
        relativePath: String,
        fileManager: FileManager
    ) throws -> [MemoryEventDraft] {
        guard let data = fileManager.contents(atPath: fileURL.path) else {
            throw MemorySourceAdapterError.unreadableData(path: fileURL.path)
        }
        if data.isEmpty { return [] }

        let ext = fileURL.pathExtension.lowercased()
        if ext == "json" {
            return parseJSONData(
                provider: provider,
                data: data,
                relativePath: relativePath,
                fallbackRawPayload: String(data: data, encoding: .utf8)
            )
        }

        if ext == "jsonl" || ext == "ndjson" || fileURL.lastPathComponent.lowercased().contains("jsonl") {
            return parseJSONLinesData(provider: provider, data: data, relativePath: relativePath)
        }

        if ext == "db" || ext == "sqlite" || ext == "sqlite3" || ext == "vscdb" {
            return parseSQLiteData(provider: provider, fileURL: fileURL, relativePath: relativePath)
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw MemorySourceAdapterError.unreadableData(path: fileURL.path)
        }
        return parseText(provider: provider, text: text, relativePath: relativePath)
    }

    private static func parseSQLiteData(
        provider: MemoryProviderKind,
        fileURL: URL,
        relativePath: String
    ) -> [MemoryEventDraft] {
        var db: OpaquePointer?
        let openCode = sqlite3_open_v2(fileURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard openCode == SQLITE_OK, let db else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }

        let tableNames = sqliteTableNames(db: db)
        if tableNames.contains("blobs") {
            let turns = readConversationTurnsFromBlobTable(provider: provider, db: db)
            let paired = makeConversationPairDrafts(provider: provider, relativePath: relativePath, turns: turns)
            if !paired.isEmpty { return paired }
        }

        if tableNames.contains("itemtable") {
            let turns = readConversationTurnsFromItemTable(provider: provider, db: db)
            let paired = makeConversationPairDrafts(provider: provider, relativePath: relativePath, turns: turns)
            if !paired.isEmpty { return paired }
        }

        return []
    }

    private static func sqliteTableNames(db: OpaquePointer) -> Set<String> {
        let sql = "SELECT name FROM sqlite_master WHERE type='table';"
        guard let statement = sqlitePrepare(db: db, sql: sql) else { return [] }
        defer { sqlite3_finalize(statement) }

        var names: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqliteReadString(statement: statement, column: 0) {
                names.insert(name.lowercased())
            }
        }
        return names
    }

    private static func readConversationTurnsFromBlobTable(
        provider: MemoryProviderKind,
        db: OpaquePointer
    ) -> [ConversationTurnCandidate] {
        let sql = "SELECT data FROM blobs ORDER BY rowid ASC;"
        guard let statement = sqlitePrepare(db: db, sql: sql) else { return [] }
        defer { sqlite3_finalize(statement) }

        var turns: [ConversationTurnCandidate] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let data = sqliteReadBlob(statement: statement, column: 0),
                  let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                  let dictionary = object as? [String: Any] else {
                continue
            }
            turns.append(contentsOf: conversationTurnsFromJSONDictionary(
                provider: provider,
                dictionary: dictionary,
                fallbackTimestamp: Date()
            ))
        }
        return turns
    }

    private static func readConversationTurnsFromItemTable(
        provider: MemoryProviderKind,
        db: OpaquePointer
    ) -> [ConversationTurnCandidate] {
        let sql = "SELECT key, value FROM ItemTable ORDER BY key ASC;"
        guard let statement = sqlitePrepare(db: db, sql: sql) else { return [] }
        defer { sqlite3_finalize(statement) }

        var turns: [ConversationTurnCandidate] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let key = sqliteReadString(statement: statement, column: 0)?.lowercased(),
                  let valueData = sqliteReadBlob(statement: statement, column: 1) else {
                continue
            }

            if key == "composer.composerdata",
               let object = try? JSONSerialization.jsonObject(with: valueData, options: [.fragmentsAllowed]),
               let dictionary = object as? [String: Any] {
                if let composers = dictionary["allComposers"] as? [Any] {
                    for composerNode in composers {
                        guard let composer = composerNode as? [String: Any] else { continue }
                        let projectName = readString(from: composer, keys: ["name", "subtitle"]) ?? "Cursor Composer"
                        let createdAt = readDate(from: composer, keys: ["createdAt", "lastUpdatedAt"]) ?? Date()
                        let metadata = flattenMetadata(from: composer)
                        turns.append(ConversationTurnCandidate(
                            role: "assistant",
                            body: "Composer thread: \(projectName)",
                            timestamp: createdAt,
                            metadata: metadata,
                            isSummaryOnly: true
                        ))
                    }
                }
            }
        }
        return turns
    }

    private static func conversationTurnsFromJSONDictionary(
        provider: MemoryProviderKind,
        dictionary: [String: Any],
        fallbackTimestamp: Date
    ) -> [ConversationTurnCandidate] {
        var turns: [ConversationTurnCandidate] = []

        let role = readString(from: dictionary, keys: ["role", "author", "speaker", "type"])?.lowercased()
        let body = extractMessageBody(from: dictionary) ?? extractMessageContent(from: dictionary["content"])
        let timestamp = readDate(from: dictionary, keys: ["timestamp", "created_at", "createdAt", "time", "date"]) ?? fallbackTimestamp

        if let role, ["user", "assistant", "ai", "model", "bot"].contains(role), let body,
           let normalized = normalizedConversationBody(forRole: role, rawBody: body),
           !shouldSkipMessage(provider: provider, role: role, body: normalized, metadata: dictionary) {
            var metadata = flattenMetadata(from: dictionary)
            if let workspacePath = extractWorkspacePath(from: normalized) {
                metadata["workspace"] = workspacePath
                metadata["project"] = URL(fileURLWithPath: workspacePath).lastPathComponent
            }
            turns.append(ConversationTurnCandidate(
                role: role,
                body: normalized,
                timestamp: timestamp,
                metadata: metadata,
                isSummaryOnly: false
            ))
        }

        if let nestedMessages = firstMessageArray(in: dictionary), !nestedMessages.isEmpty {
            turns.append(contentsOf: parseConversationTurnsFromMessageArray(
                provider: provider,
                messages: nestedMessages,
                fallbackTimestamp: timestamp
            ))
        }

        return turns
    }

    private static func parseJSONData(
        provider: MemoryProviderKind,
        data: Data,
        relativePath: String,
        fallbackRawPayload: String?
    ) -> [MemoryEventDraft] {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            if let fallbackRawPayload {
                return parseText(provider: provider, text: fallbackRawPayload, relativePath: relativePath)
            }
            return []
        }

        if let array = object as? [Any] {
            var drafts: [MemoryEventDraft] = []
            drafts.reserveCapacity(array.count)
            for entry in array {
                drafts.append(contentsOf: parseJSONNode(provider: provider, node: entry, relativePath: relativePath))
            }
            return drafts
        }

        return parseJSONNode(provider: provider, node: object, relativePath: relativePath)
    }

    private static func parseJSONLinesData(
        provider: MemoryProviderKind,
        data: Data,
        relativePath: String
    ) -> [MemoryEventDraft] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let lines = text.split(whereSeparator: \.isNewline)

        var drafts: [MemoryEventDraft] = []
        drafts.reserveCapacity(lines.count)
        var conversationTurns: [ConversationTurnCandidate] = []
        conversationTurns.reserveCapacity(lines.count)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let lineData = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData, options: [.fragmentsAllowed]) else {
                continue
            }
            if let dictionary = object as? [String: Any] {
                let codexTurnCandidates = parseConversationTurnCandidates(
                    provider: provider,
                    dictionary: dictionary
                )
                if !codexTurnCandidates.isEmpty {
                    conversationTurns.append(contentsOf: codexTurnCandidates)
                    continue
                }

                let genericTurnCandidates = parseGenericConversationTurnCandidates(
                    provider: provider,
                    dictionary: dictionary,
                    fallbackTimestamp: Date()
                )
                if !genericTurnCandidates.isEmpty {
                    conversationTurns.append(contentsOf: genericTurnCandidates)
                    continue
                }
            }
            drafts.append(contentsOf: parseJSONNode(provider: provider, node: object, relativePath: relativePath))
        }

        let pairedDrafts = makeConversationPairDrafts(
            provider: provider,
            relativePath: relativePath,
            turns: conversationTurns
        )
        if !pairedDrafts.isEmpty {
            return pairedDrafts
        }

        return drafts
    }

    private static func parseConversationTurnCandidates(
        provider: MemoryProviderKind,
        dictionary: [String: Any]
    ) -> [ConversationTurnCandidate] {
        let eventType = readString(from: dictionary, keys: ["type"])?.lowercased() ?? ""
        guard let payload = dictionary["payload"] as? [String: Any] else { return [] }
        let timestamp = readDate(from: dictionary, keys: ["timestamp"])
            ?? readDate(from: payload, keys: ["timestamp", "created_at", "createdAt", "time", "date"])
            ?? Date()

        if eventType == "response_item" {
            let payloadType = readString(from: payload, keys: ["type"])?.lowercased() ?? ""
            if payloadType == "message" {
                let role = readString(from: payload, keys: ["role"])?.lowercased() ?? ""
                let body = extractMessageBody(from: payload) ?? extractMessageContent(from: payload["content"])
                guard let body else { return [] }
                guard let normalized = normalizedConversationBody(forRole: role, rawBody: body),
                      !shouldSkipMessage(provider: provider, role: role, body: normalized, metadata: payload) else {
                    return []
                }
                return [ConversationTurnCandidate(
                    role: role,
                    body: normalized,
                    timestamp: timestamp,
                    metadata: flattenMetadata(from: payload),
                    isSummaryOnly: false
                )]
            }
            return []
        }

        if eventType == "event_msg" {
            let payloadType = readString(from: payload, keys: ["type"])?.lowercased() ?? ""
            if payloadType == "user_message",
               let message = readString(from: payload, keys: ["message"]),
               let normalized = normalizedConversationBody(forRole: "user", rawBody: message) {
                return [ConversationTurnCandidate(
                    role: "user",
                    body: normalized,
                    timestamp: timestamp,
                    metadata: flattenMetadata(from: payload),
                    isSummaryOnly: false
                )]
            }
            if payloadType == "agent_message",
               let message = readString(from: payload, keys: ["message"]),
               let normalized = normalizedConversationBody(forRole: "assistant", rawBody: message) {
                return [ConversationTurnCandidate(
                    role: "assistant",
                    body: normalized,
                    timestamp: timestamp,
                    metadata: flattenMetadata(from: payload),
                    isSummaryOnly: false
                )]
            }
            if payloadType == "assistant_message",
               let message = readString(from: payload, keys: ["message"]),
               let normalized = normalizedConversationBody(forRole: "assistant", rawBody: message) {
                return [ConversationTurnCandidate(
                    role: "assistant",
                    body: normalized,
                    timestamp: timestamp,
                    metadata: flattenMetadata(from: payload),
                    isSummaryOnly: false
                )]
            }
            if payloadType == "agent_reasoning",
               let summary = readString(from: payload, keys: ["text"]),
               let normalized = normalizedConversationBody(forRole: "assistant", rawBody: summary) {
                return [ConversationTurnCandidate(
                    role: "assistant",
                    body: normalized,
                    timestamp: timestamp,
                    metadata: flattenMetadata(from: payload),
                    isSummaryOnly: true
                )]
            }
        }

        return []
    }

    private static func parseGenericConversationTurnCandidates(
        provider: MemoryProviderKind,
        dictionary: [String: Any],
        fallbackTimestamp: Date
    ) -> [ConversationTurnCandidate] {
        var turns: [ConversationTurnCandidate] = []

        if let messages = firstMessageArray(in: dictionary), !messages.isEmpty {
            turns.append(contentsOf: parseConversationTurnsFromMessageArray(
                provider: provider,
                messages: messages,
                fallbackTimestamp: fallbackTimestamp
            ))
        }

        let directRole = readString(from: dictionary, keys: ["role", "author", "speaker", "message_role", "kind"])?.lowercased()
        let directBody = extractMessageBody(from: dictionary) ?? extractMessageContent(from: dictionary["content"])
        if let directRole,
           ["user", "assistant", "ai", "model", "bot"].contains(directRole),
           let directBody,
           let normalized = normalizedConversationBody(forRole: directRole, rawBody: directBody),
           !shouldSkipMessage(provider: provider, role: directRole, body: normalized, metadata: dictionary) {
            turns.append(ConversationTurnCandidate(
                role: directRole,
                body: normalized,
                timestamp: readDate(from: dictionary, keys: ["timestamp", "created_at", "createdAt", "time", "date"]) ?? fallbackTimestamp,
                metadata: flattenMetadata(from: dictionary),
                isSummaryOnly: false
            ))
        }

        return turns
    }

    private static func parseConversationTurnsFromMessageArray(
        provider: MemoryProviderKind,
        messages: [Any],
        fallbackTimestamp: Date
    ) -> [ConversationTurnCandidate] {
        messages.compactMap { messageNode in
            guard let message = messageNode as? [String: Any] else { return nil }
            let role = readString(from: message, keys: ["role", "author", "speaker", "type"])?.lowercased() ?? ""
            guard ["user", "assistant", "ai", "model", "bot"].contains(role) else { return nil }
            let body = extractMessageBody(from: message) ?? extractMessageContent(from: message["content"])
            guard let body,
                  let normalized = normalizedConversationBody(forRole: role, rawBody: body),
                  !shouldSkipMessage(provider: provider, role: role, body: normalized, metadata: message) else {
                return nil
            }
            var metadata = flattenMetadata(from: message)
            if let workspacePath = extractWorkspacePath(from: normalized) {
                metadata["workspace"] = workspacePath
                metadata["project"] = URL(fileURLWithPath: workspacePath).lastPathComponent
            }
            return ConversationTurnCandidate(
                role: role,
                body: normalized,
                timestamp: readDate(from: message, keys: ["timestamp", "created_at", "createdAt", "time", "date"]) ?? fallbackTimestamp,
                metadata: metadata,
                isSummaryOnly: false
            )
        }
    }

    private static func makeConversationPairDrafts(
        provider: MemoryProviderKind,
        relativePath: String,
        turns: [ConversationTurnCandidate]
    ) -> [MemoryEventDraft] {
        struct ConversationPairRecord {
            let question: String
            let answer: String
            let timestamp: Date
            let userMetadata: [String: String]
            let assistantMetadata: [String: String]
            let assistantSummaries: [String]
            let issueKey: String
            let attemptNumber: Int
            let outcomeStatus: String
            let outcomeEvidence: String
        }

        guard !turns.isEmpty else { return [] }
        let orderedTurns = turns.sorted { $0.timestamp < $1.timestamp }

        var drafts: [MemoryEventDraft] = []
        var pendingUserTurn: ConversationTurnCandidate?
        var pendingAssistantSummaries: [String] = []
        var sessionPairSummaries: [String] = []
        var pairRecords: [ConversationPairRecord] = []
        var attemptsByIssue: [String: Int] = [:]

        for turn in orderedTurns {
            let role = MemoryTextNormalizer.collapsedWhitespace(turn.role).lowercased()
            if role == "user" {
                pendingUserTurn = turn
                pendingAssistantSummaries = []
                continue
            }

            if role == "assistant" {
                if turn.isSummaryOnly {
                    pendingAssistantSummaries.append(turn.body)
                    continue
                }
                guard let userTurn = pendingUserTurn else { continue }

                let question = userTurn.body
                let answer = turn.body
                let issueKey = issueKeyForQuestion(question)
                let nextAttemptNumber = (attemptsByIssue[issueKey] ?? 0) + 1
                attemptsByIssue[issueKey] = nextAttemptNumber
                let outcomeStatus = inferOutcomeStatus(from: answer)
                let outcomeEvidence = inferOutcomeEvidence(from: answer)
                if shouldSkipLowValueConversationPair(
                    question: question,
                    answer: answer,
                    outcomeStatus: outcomeStatus
                ) {
                    pendingUserTurn = nil
                    pendingAssistantSummaries = []
                    continue
                }

                pairRecords.append(ConversationPairRecord(
                    question: question,
                    answer: answer,
                    timestamp: turn.timestamp,
                    userMetadata: userTurn.metadata,
                    assistantMetadata: turn.metadata,
                    assistantSummaries: pendingAssistantSummaries,
                    issueKey: issueKey,
                    attemptNumber: nextAttemptNumber,
                    outcomeStatus: outcomeStatus,
                    outcomeEvidence: outcomeEvidence
                ))

                sessionPairSummaries.append(
                    "Q: \(question)\nA: \(answer)\nStatus: \(outcomeStatus)"
                )
                pendingUserTurn = nil
                pendingAssistantSummaries = []
            }
        }

        let attemptsTotalByIssue = pairRecords.reduce(into: [String: Int]()) { partial, record in
            partial[record.issueKey, default: 0] += 1
        }
        let latestFixedAttemptByIssue = pairRecords.reduce(into: [String: Int]()) { partial, record in
            guard record.outcomeStatus == "fixed" else { return }
            let previous = partial[record.issueKey] ?? 0
            if record.attemptNumber > previous {
                partial[record.issueKey] = record.attemptNumber
            }
        }

        for record in pairRecords {
            var body = "Question:\n\(record.question)\n\nResponse:\n\(record.answer)"
            if !record.assistantSummaries.isEmpty {
                let summary = record.assistantSummaries.joined(separator: "\n")
                body += "\n\nSession notes:\n\(summary)"
            }

            let title = MemoryTextNormalizer.normalizedTitle(
                "Q&A: \(String(record.question.prefix(72)))",
                fallback: "Conversation Q&A"
            )
            let nativeSummary = MemoryTextNormalizer.normalizedSummary(
                "Q: \(record.question) A: \(record.answer)",
                limit: 220
            )

            var metadata = record.userMetadata
            for (key, value) in record.assistantMetadata {
                metadata["assistant_\(key)"] = value
            }
            metadata["conversation_pair"] = "true"
            metadata["message_role"] = "user_assistant_pair"
            metadata["question_text"] = MemoryTextNormalizer.normalizedSummary(record.question, limit: 900)
            metadata["response_text"] = MemoryTextNormalizer.normalizedSummary(record.answer, limit: 1200)
            metadata["issue_key"] = record.issueKey
            metadata["attempt_number"] = "\(record.attemptNumber)"
            metadata["attempt_count"] = "\(attemptsTotalByIssue[record.issueKey] ?? record.attemptNumber)"
            metadata["is_latest_attempt"] = (
                record.attemptNumber == (attemptsTotalByIssue[record.issueKey] ?? record.attemptNumber)
            ) ? "true" : "false"
            metadata["outcome_status"] = record.outcomeStatus
            metadata["outcome_evidence"] = record.outcomeEvidence
            metadata["fix_summary"] = inferFixSummary(from: record.answer)
            if let latestFixedAttempt = latestFixedAttemptByIssue[record.issueKey] {
                if record.attemptNumber < latestFixedAttempt {
                    metadata["validation_state"] = "invalidated"
                    metadata["invalidated_by_attempt"] = "\(latestFixedAttempt)"
                } else if record.attemptNumber == latestFixedAttempt {
                    metadata["validation_state"] = "indexed-validated"
                } else {
                    metadata["validation_state"] = "unvalidated"
                }
            } else {
                metadata["validation_state"] = "unvalidated"
            }

            drafts.append(makeDraft(
                provider: provider,
                relativePath: relativePath,
                title: title,
                body: body,
                kind: .conversation,
                timestamp: record.timestamp,
                nativeSummary: nativeSummary,
                metadata: metadata,
                rawPayload: nil
            ))
        }

        if sessionPairSummaries.count >= 2 {
            let summaryBody = sessionPairSummaries
                .prefix(6)
                .enumerated()
                .map { index, pairSummary in
                    "\(index + 1). \(pairSummary)"
                }
                .joined(separator: "\n\n")

            drafts.append(makeDraft(
                provider: provider,
                relativePath: relativePath,
                title: "Session Summary",
                body: summaryBody,
                kind: .summary,
                timestamp: orderedTurns.last?.timestamp ?? Date(),
                nativeSummary: "Summary of key question-and-response pairs from this session.",
                metadata: ["session_summary": "true", "pair_count": "\(sessionPairSummaries.count)"],
                rawPayload: nil
            ))
        }

        return drafts
    }

    private static func issueKeyForQuestion(_ question: String) -> String {
        let normalized = MemoryTextNormalizer
            .collapsedWhitespace(question)
            .lowercased()
        if normalized.isEmpty { return "issue-general" }

        let stopWords: Set<String> = [
            "the", "a", "an", "to", "for", "and", "or", "of", "in", "on", "with",
            "this", "that", "it", "is", "are", "be", "can", "could", "would", "should",
            "you", "we", "i", "please", "my", "me", "our", "your", "just", "same",
            "help", "need", "want", "thanks", "thank", "hello", "hi", "hey", "okay", "ok"
        ]
        let strongIssueTokens: Set<String> = [
            "fix", "fixed", "error", "errors", "bug", "issue", "failing", "failed", "failure",
            "compile", "build", "test", "tests", "crash", "timeout", "memory", "database",
            "migration", "adapter", "parser", "metadata", "swift", "sqlite", "json"
        ]

        var tokens: [String] = []
        var strongTokens: [String] = []
        let parts = normalized.components(separatedBy: CharacterSet.alphanumerics.inverted)
        for token in parts {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 3, !stopWords.contains(trimmed) else { continue }
            if !tokens.contains(trimmed) {
                tokens.append(trimmed)
            }
            if strongIssueTokens.contains(trimmed), !strongTokens.contains(trimmed) {
                strongTokens.append(trimmed)
            }
            if tokens.count >= 8 { break }
        }

        let selectedTokens = strongTokens.isEmpty ? tokens : strongTokens + tokens.filter { !strongTokens.contains($0) }
        let meaningfulTokens = selectedTokens.filter { !$0.allSatisfy(\.isNumber) }.prefix(5)

        if meaningfulTokens.isEmpty || (meaningfulTokens.count == 1 && meaningfulTokens.first?.count ?? 0 < 5) {
            return "issue-q\(deterministicIssueKeyHash(normalized))"
        }
        return "issue-\(meaningfulTokens.joined(separator: "-"))"
    }

    private static func inferOutcomeStatus(from answer: String) -> String {
        let normalized = MemoryTextNormalizer.collapsedWhitespace(answer).lowercased()
        if normalized.isEmpty { return "unknown" }

        let failedNeedles = [
            "unable", "can't", "cannot", "failed", "blocked", "didn't work", "not working"
        ]
        let planningNeedles = [
            "i'll ", "i will ", "i'm going to", "i am going to", "next, i", "let me ",
            "plan:", "i can ", "i could ", "we should "
        ]
        let strongCompletionNeedles = [
            "i fixed", "fixed by", "resolved by", "i resolved", "i implemented",
            "i have implemented", "i've implemented", "applied the fix", "patched",
            "made the following changes", "changes made", "updated the code",
            "build succeeded", "swift build succeeded", "tests passed", "verified"
        ]

        if failedNeedles.contains(where: normalized.contains) {
            return "not_fixed"
        }
        if strongCompletionNeedles.contains(where: normalized.contains) {
            return "fixed"
        }
        if planningNeedles.contains(where: normalized.contains) {
            return "attempted"
        }
        return "responded"
    }

    private static func inferOutcomeEvidence(from answer: String) -> String {
        let lines = answer
            .components(separatedBy: .newlines)
            .map { MemoryTextNormalizer.normalizedBody($0) }
            .filter { !$0.isEmpty }
        if let first = lines.first {
            return MemoryTextNormalizer.normalizedSummary(first, limit: 220)
        }
        return MemoryTextNormalizer.normalizedSummary(answer, limit: 220)
    }

    private static func inferFixSummary(from answer: String) -> String {
        let normalized = MemoryTextNormalizer.normalizedBody(answer)
        guard !normalized.isEmpty else { return "" }
        let lines = normalized
            .components(separatedBy: .newlines)
            .map { MemoryTextNormalizer.normalizedBody($0) }
            .filter { !$0.isEmpty }

        let selected = lines.prefix(3).joined(separator: " ")
        let concise = MemoryTextNormalizer.normalizedSummary(selected, limit: 260)
        if concise.isEmpty {
            return MemoryTextNormalizer.normalizedSummary(normalized, limit: 260)
        }
        return concise
    }

    private static func shouldSkipLowValueConversationPair(
        question: String,
        answer: String,
        outcomeStatus: String
    ) -> Bool {
        let normalizedQuestion = MemoryTextNormalizer.collapsedWhitespace(question).lowercased()
        let normalizedAnswer = MemoryTextNormalizer.collapsedWhitespace(answer).lowercased()
        if normalizedQuestion.isEmpty || normalizedAnswer.isEmpty {
            return true
        }

        let trivialPrompts: Set<String> = [
            "hi", "hello", "hey", "yo", "sup", "ok", "okay", "thanks", "thank you", "test"
        ]
        if trivialPrompts.contains(normalizedQuestion) {
            return true
        }

        let normalizedQuestionWordCount = normalizedQuestion.split(separator: " ").count
        if normalizedQuestionWordCount < 3 {
            return true
        }
        if isLikelyGreetingOrChitChat(normalizedQuestion) {
            return true
        }
        if isLikelyPathOnlyPrompt(normalizedQuestion) {
            return true
        }
        if isLikelyLogDump(normalizedQuestion) || isLikelyLogDump(normalizedAnswer) {
            return true
        }

        let assistantGreeterPhrases = [
            "how can i help",
            "how can i assist",
            "what can i help",
            "let me know what you'd like",
            "anything else in the project"
        ]
        if assistantGreeterPhrases.contains(where: normalizedAnswer.contains),
           (outcomeStatus == "responded" || outcomeStatus == "attempted") {
            return true
        }

        let highSignalNeedles = [
            "fix", "error", "bug", "issue", "failed", "doesn't", "doesnt", "not working",
            "implement", "refactor", "rewrite", "style", "theme", "performance", "test",
            "build", "compile", "database", "migration", "provider", "memory", "index"
        ]
        let hasHighSignalQuestionIntent = highSignalNeedles.contains(where: normalizedQuestion.contains)
        let hasHighSignalAnswerIntent = highSignalNeedles.contains(where: normalizedAnswer.contains)

        if !hasHighSignalQuestionIntent && !hasHighSignalAnswerIntent {
            return true
        }

        return false
    }

    private static func isLikelyGreetingOrChitChat(_ text: String) -> Bool {
        let greetings: Set<String> = [
            "good morning", "good afternoon", "good evening", "how are you", "how's it going",
            "whats up", "what's up", "nice to meet you", "thank you", "thanks again"
        ]
        if greetings.contains(text) { return true }
        if text.hasPrefix("hi ") || text.hasPrefix("hello ") || text.hasPrefix("hey ") {
            return true
        }
        return false
    }

    private static func isLikelyPathOnlyPrompt(_ text: String) -> Bool {
        if text.count > 240 { return false }
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty, lines.count <= 3 else { return false }

        var pathLikeCount = 0
        for line in lines {
            if line.hasPrefix("/") || line.hasPrefix("./") || line.hasPrefix("../") || line.hasPrefix("~/") {
                pathLikeCount += 1
                continue
            }
            if line.contains("/") && !line.contains(" ") && line.range(of: #"\.[a-z0-9]{1,8}$"#, options: .regularExpression) != nil {
                pathLikeCount += 1
                continue
            }
            if line.range(of: #"^[a-zA-Z]:\\[^\\]+"#, options: .regularExpression) != nil {
                pathLikeCount += 1
                continue
            }
        }
        return pathLikeCount == lines.count
    }

    private static func isLikelyLogDump(_ text: String) -> Bool {
        let lines = text.components(separatedBy: .newlines)
        if lines.count < 6 { return false }

        var signalCount = 0
        for line in lines.prefix(40) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("at ") || trimmed.contains("stack trace") || trimmed.contains("exception") {
                signalCount += 1
                continue
            }
            if trimmed.contains("exit code:") || trimmed.contains("wall time:") || trimmed.contains("chunk id:") {
                signalCount += 1
                continue
            }
            if trimmed.range(of: #"^\d{4}-\d{2}-\d{2}[ t]"#, options: .regularExpression) != nil {
                signalCount += 1
                continue
            }
            if trimmed.range(of: #"^\[[a-z]+\]"#, options: .regularExpression) != nil {
                signalCount += 1
                continue
            }
        }
        return signalCount >= 3
    }

    private static func deterministicIssueKeyHash(_ value: String) -> String {
        var hash: UInt64 = 14695981039346656037
        let prime: UInt64 = 1099511628211
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= prime
        }
        let hex = String(hash, radix: 16, uppercase: false)
        return String(hex.suffix(12))
    }

    private static func parseJSONNode(
        provider: MemoryProviderKind,
        node: Any,
        relativePath: String
    ) -> [MemoryEventDraft] {
        if let array = node as? [Any] {
            return array.flatMap { parseJSONNode(provider: provider, node: $0, relativePath: relativePath) }
        }

        guard let dictionary = node as? [String: Any] else {
            let body = MemoryTextNormalizer.normalizedBody("\(node)")
            guard !body.isEmpty else { return [] }
            return [makeDraft(
                provider: provider,
                relativePath: relativePath,
                title: "\(provider.displayName) Event",
                body: body,
                kind: inferKind(from: relativePath, valueHint: nil),
                timestamp: Date(),
                nativeSummary: nil,
                metadata: [:],
                rawPayload: body
            )]
        }

        if let messages = firstMessageArray(in: dictionary), !messages.isEmpty {
            let turns = parseConversationTurnsFromMessageArray(
                provider: provider,
                messages: messages,
                fallbackTimestamp: Date()
            )
            let pairedDrafts = makeConversationPairDrafts(
                provider: provider,
                relativePath: relativePath,
                turns: turns
            )
            if !pairedDrafts.isEmpty {
                return pairedDrafts
            }
        }

        let title = readString(from: dictionary, keys: ["title", "subject", "name", "label"])
            ?? MemoryTextNormalizer.normalizedTitle(fileStem(from: relativePath))
        let explicitBody = readString(
            from: dictionary,
            keys: ["content", "text", "message", "body", "prompt", "response", "completion", "output", "input"]
        ) ?? extractNestedText(from: dictionary)
        if explicitBody == nil && shouldSkipLowSignalDictionary(dictionary) {
            return []
        }
        let body = explicitBody ?? serializeJSON(dictionary: dictionary)
        let timestamp = readDate(from: dictionary, keys: ["timestamp", "created_at", "createdAt", "time", "date"])
            ?? inferredTimestamp(from: [
                title,
                relativePath,
                readString(from: dictionary, keys: ["id", "session_id", "conversation_id", "name"]) ?? "",
                body
            ])
            ?? Date()
        let kindHint = readString(from: dictionary, keys: ["kind", "type", "event", "category", "role"])
        if shouldSkipMessage(provider: provider, role: kindHint, body: body, metadata: dictionary) {
            return []
        }
        let kind = inferKind(from: relativePath, valueHint: kindHint)
        let summary = readString(from: dictionary, keys: ["summary", "native_summary", "abstract"])

        return [makeDraft(
            provider: provider,
            relativePath: relativePath,
            title: title,
            body: body,
            kind: kind,
            timestamp: timestamp,
            nativeSummary: summary,
            metadata: flattenMetadata(from: dictionary),
            rawPayload: serializeJSON(dictionary: dictionary)
        )]
    }

    private static func parseText(
        provider: MemoryProviderKind,
        text: String,
        relativePath: String
    ) -> [MemoryEventDraft] {
        let normalized = MemoryTextNormalizer.normalizedBody(text)
        guard !normalized.isEmpty else { return [] }

        if relativePath.lowercased().hasSuffix(".md") || relativePath.lowercased().hasSuffix(".markdown") {
            let sections = markdownSections(from: normalized)
            if !sections.isEmpty {
                return sections.map { section in
                    let kind = inferKind(from: relativePath, valueHint: section.title)
                    return makeDraft(
                        provider: provider,
                        relativePath: relativePath,
                        title: section.title,
                        body: section.body,
                        kind: kind,
                        timestamp: Date(),
                        nativeSummary: nil,
                        metadata: [:],
                        rawPayload: nil
                    )
                }
            }
        }

        let paragraphs = normalized
            .components(separatedBy: "\n\n")
            .map { MemoryTextNormalizer.normalizedBody($0) }
            .filter { !$0.isEmpty }

        if !paragraphs.isEmpty {
            let chunkedParagraphs = paragraphs.flatMap { chunkText($0, maxCharacters: 900) }
            if chunkedParagraphs.count <= 64 {
                return chunkedParagraphs.enumerated().map { index, paragraph in
                    let prefix = chunkedParagraphs.count > 1 ? "Part \(index + 1): " : ""
                    let title = MemoryTextNormalizer.normalizedTitle(prefix + String(paragraph.prefix(72)))
                    let kind = inferKind(from: relativePath, valueHint: title)
                    return makeDraft(
                        provider: provider,
                        relativePath: relativePath,
                        title: title,
                        body: paragraph,
                        kind: kind,
                        timestamp: Date(),
                        nativeSummary: nil,
                        metadata: ["chunk_index": "\(index + 1)", "chunk_total": "\(chunkedParagraphs.count)"],
                        rawPayload: nil
                    )
                }
            }
        }

        let title = MemoryTextNormalizer.normalizedTitle(fileStem(from: relativePath))
        let kind = inferKind(from: relativePath, valueHint: title)
        return [makeDraft(
            provider: provider,
            relativePath: relativePath,
            title: title,
            body: normalized,
            kind: kind,
            timestamp: Date(),
            nativeSummary: nil,
            metadata: [:],
            rawPayload: nil
        )]
    }

    private static func makeDraft(
        provider: MemoryProviderKind,
        relativePath: String,
        title: String,
        body: String,
        kind: MemoryEventKind,
        timestamp: Date,
        nativeSummary: String?,
        metadata: [String: String],
        rawPayload: String?
    ) -> MemoryEventDraft {
        let normalizedTitle = MemoryTextNormalizer.normalizedTitle(title)
        let normalizedBody = MemoryTextNormalizer.normalizedBody(body)
        let allKeywords = MemoryTextNormalizer.normalizedKeywords(
            MemoryTextNormalizer.keywords(from: normalizedTitle + " " + normalizedBody, limit: 20)
        )

        let summary = nativeSummary.map { MemoryTextNormalizer.normalizedSummary($0) }
        let inferredPlan = MemoryTextNormalizer.inferPlanContent(path: relativePath, kind: kind, body: normalizedBody)

        var enrichedMetadata = metadata
        enrichedMetadata["relative_path"] = relativePath
        enrichedMetadata["event_kind"] = kind.rawValue

        return MemoryEventDraft(
            kind: kind,
            title: normalizedTitle,
            body: normalizedBody,
            timestamp: timestamp,
            nativeSummary: summary,
            keywords: allKeywords,
            isPlanContent: inferredPlan,
            metadata: enrichedMetadata,
            rawPayload: rawPayload
        )
    }

    private static func firstMessageArray(in dictionary: [String: Any]) -> [Any]? {
        let candidateKeys = ["messages", "chat_messages", "conversation", "turns", "items", "entries"]
        for key in candidateKeys {
            if let messages = dictionary[key] as? [Any], !messages.isEmpty {
                return messages
            }
        }
        if let payload = dictionary["data"] as? [String: Any] {
            return firstMessageArray(in: payload)
        }
        return nil
    }

    private static func extractMessageBody(from message: [String: Any]) -> String? {
        if let direct = readString(from: message, keys: ["content", "text", "message", "body", "value", "prompt", "response"]) {
            return direct
        }
        if let contentDictionary = message["content"] as? [String: Any],
           let nested = extractNestedText(from: contentDictionary) {
            return nested
        }
        if let parts = message["parts"] as? [Any] {
            let combined = parts.compactMap { part -> String? in
                if let value = part as? String {
                    let normalized = MemoryTextNormalizer.normalizedBody(value)
                    return normalized.isEmpty ? nil : normalized
                }
                if let dictionary = part as? [String: Any] {
                    return extractNestedText(from: dictionary)
                }
                return nil
            }.joined(separator: "\n")
            let normalized = MemoryTextNormalizer.normalizedBody(combined)
            if !normalized.isEmpty {
                return normalized
            }
        }
        return extractNestedText(from: message)
    }

    private static func extractMessageContent(from content: Any?) -> String? {
        guard let content else { return nil }
        if let contentString = content as? String {
            let normalized = MemoryTextNormalizer.normalizedBody(contentString)
            return normalized.isEmpty ? nil : normalized
        }
        guard let blocks = content as? [Any] else { return nil }

        let combined = blocks.compactMap { block -> String? in
            if let blockString = block as? String {
                let normalized = MemoryTextNormalizer.normalizedBody(blockString)
                return normalized.isEmpty ? nil : normalized
            }
            guard let blockDictionary = block as? [String: Any] else { return nil }
            let blockType = readString(from: blockDictionary, keys: ["type"])?.lowercased() ?? ""
            if ["input_text", "output_text", "text"].contains(blockType),
               let text = readString(from: blockDictionary, keys: ["text"]) {
                return text
            }
            return extractNestedText(from: blockDictionary)
        }.joined(separator: "\n")

        let normalized = MemoryTextNormalizer.normalizedBody(combined)
        return normalized.isEmpty ? nil : normalized
    }

    private static func shouldSkipMessage(
        provider: MemoryProviderKind,
        role: String?,
        body: String,
        metadata: [String: Any]
    ) -> Bool {
        let normalizedRole = MemoryTextNormalizer.collapsedWhitespace(role ?? "").lowercased()
        if ["tool", "system", "analysis", "thinking", "reasoning", "trace"].contains(normalizedRole) {
            return true
        }

        let normalizedBody = MemoryTextNormalizer.collapsedWhitespace(body).lowercased()
        if normalizedBody.isEmpty { return true }
        if normalizedBody.hasPrefix("{") && normalizedBody.hasSuffix("}") && normalizedBody.count > 240 {
            return true
        }
        let noisyPhrases = ["tool_call", "tool result", "internal reasoning", "chain-of-thought", "thinking:"]
        if noisyPhrases.contains(where: normalizedBody.contains) {
            return true
        }
        if let messageType = metadata["type"] as? String,
           ["tool", "trace", "thinking", "meta"].contains(messageType.lowercased()) {
            return true
        }

        // Skip procedural commentary updates, but keep substantive assistant responses.
        if provider == .codex || provider == .opencode || provider == .claude {
            let planningPrefixes = [
                "i'll ", "i will ", "i’m ", "i am ", "let me ", "next, i", "plan updated",
                "i can ", "i'm going to", "i am going to", "i'll do", "i’ll do"
            ]
            let isAssistantRole = ["assistant", "ai", "model", "bot"].contains(normalizedRole)
            let phase = (metadata["phase"] as? String)?.lowercased()
            let isCommentaryPhase = phase == "commentary"
            if isAssistantRole, isCommentaryPhase,
               planningPrefixes.contains(where: { normalizedBody.hasPrefix($0) }) {
                return true
            }
        }
        return false
    }

    private static func normalizedConversationBody(forRole role: String, rawBody: String) -> String? {
        var body = MemoryTextNormalizer.normalizedBody(rawBody)
        guard !body.isEmpty else { return nil }

        let normalizedRole = MemoryTextNormalizer.collapsedWhitespace(role).lowercased()
        if normalizedRole == "user" {
            if body.hasPrefix("<environment_context>") || body.contains("<writable_roots>") {
                return nil
            }
            if body.localizedCaseInsensitiveContains("## My request for Codex:"),
               let range = body.range(of: "## My request for Codex:", options: [.caseInsensitive]) {
                body = MemoryTextNormalizer.normalizedBody(String(body[range.upperBound...]))
            }
            if body.localizedCaseInsensitiveContains("# Context from my IDE setup:"),
               !body.localizedCaseInsensitiveContains("## My request for Codex:") {
                return nil
            }
        }

        if normalizedRole == "assistant" {
            let lower = body.lowercased()
            if lower.hasPrefix("exit code:") || lower.hasPrefix("wall time:") {
                return nil
            }
        }

        return body.isEmpty ? nil : body
    }

    private static func extractWorkspacePath(from text: String) -> String? {
        let patterns = [
            #"Workspace Path:\s*([^\n<]+)"#,
            #"<cwd>([^<]+)</cwd>"#,
            #"\bcwd:\s*([^\n]+)"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, options: [], range: range),
                  match.numberOfRanges > 1,
                  let valueRange = Range(match.range(at: 1), in: text) else {
                continue
            }
            let value = String(text[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            if value.hasPrefix("/") {
                return URL(fileURLWithPath: value).standardizedFileURL.path
            }
        }
        return nil
    }

    private static func sqlitePrepare(db: OpaquePointer, sql: String) -> OpaquePointer? {
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard code == SQLITE_OK else {
            sqlite3_finalize(statement)
            return nil
        }
        return statement
    }

    private static func sqliteReadString(statement: OpaquePointer, column: Int32) -> String? {
        guard let raw = sqlite3_column_text(statement, column) else { return nil }
        let value = String(cString: raw)
        return value.isEmpty ? nil : value
    }

    private static func sqliteReadBlob(statement: OpaquePointer, column: Int32) -> Data? {
        let byteCount = Int(sqlite3_column_bytes(statement, column))
        guard byteCount > 0, let pointer = sqlite3_column_blob(statement, column) else {
            return nil
        }
        return Data(bytes: pointer, count: byteCount)
    }

    private static func extractNestedText(from dictionary: [String: Any]) -> String? {
        let candidateKeys = ["content", "text", "body", "message", "value", "prompt", "response", "input", "output"]
        for key in candidateKeys {
            guard let value = dictionary[key] else { continue }
            if let stringValue = value as? String {
                let normalized = MemoryTextNormalizer.normalizedBody(stringValue)
                if !normalized.isEmpty {
                    return normalized
                }
            }
            if let nested = value as? [String: Any],
               let extracted = extractNestedText(from: nested) {
                return extracted
            }
            if let list = value as? [Any] {
                let joined = list.compactMap { item -> String? in
                    if let stringItem = item as? String {
                        let normalized = MemoryTextNormalizer.normalizedBody(stringItem)
                        return normalized.isEmpty ? nil : normalized
                    }
                    if let dictionaryItem = item as? [String: Any] {
                        return extractNestedText(from: dictionaryItem)
                    }
                    return nil
                }.joined(separator: "\n")
                let normalized = MemoryTextNormalizer.normalizedBody(joined)
                if !normalized.isEmpty {
                    return normalized
                }
            }
        }
        return nil
    }

    private static func chunkText(_ value: String, maxCharacters: Int) -> [String] {
        let normalized = MemoryTextNormalizer.normalizedBody(value)
        guard normalized.count > maxCharacters else { return [normalized] }

        let sentences = normalized.components(separatedBy: "\n")
        var chunks: [String] = []
        var current = ""

        for sentence in sentences {
            let trimmed = MemoryTextNormalizer.normalizedBody(sentence)
            guard !trimmed.isEmpty else { continue }
            if current.isEmpty {
                current = trimmed
                continue
            }
            if current.count + trimmed.count + 1 <= maxCharacters {
                current += "\n" + trimmed
            } else {
                chunks.append(current)
                current = trimmed
            }
        }

        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks.isEmpty ? [normalized] : chunks
    }

    private static func readString(from dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let value = dictionary[key] else { continue }

            if let stringValue = value as? String {
                let normalized = MemoryTextNormalizer.normalizedBody(stringValue)
                if !normalized.isEmpty {
                    return normalized
                }
            }
            if let numberValue = value as? NSNumber {
                return numberValue.stringValue
            }
        }
        return nil
    }

    private static func readDate(from dictionary: [String: Any], keys: [String]) -> Date? {
        for key in keys {
            guard let value = dictionary[key] else { continue }

            if let timestamp = value as? TimeInterval {
                return parseTimestamp(timestamp)
            }

            if let intValue = value as? Int {
                return parseTimestamp(TimeInterval(intValue))
            }

            if let stringValue = value as? String {
                let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                if let numeric = TimeInterval(trimmed) {
                    return parseTimestamp(numeric)
                }
                if let parsed = fractionalISO8601Parser.date(from: trimmed)
                    ?? plainISO8601Parser.date(from: trimmed) {
                    return parsed
                }
                let fallbackFormats = [
                    "yyyy-MM-dd HH:mm:ss",
                    "yyyy-MM-dd'T'HH:mm:ss",
                    "yyyy-MM-dd"
                ]
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                for format in fallbackFormats {
                    formatter.dateFormat = format
                    if let parsed = formatter.date(from: trimmed) {
                        return parsed
                    }
                }
            }
        }
        return nil
    }

    private static func parseTimestamp(_ timestamp: TimeInterval) -> Date {
        if timestamp > 10_000_000_000 {
            return Date(timeIntervalSince1970: timestamp / 1_000)
        }
        return Date(timeIntervalSince1970: timestamp)
    }

    private static func inferredTimestamp(from candidates: [String]) -> Date? {
        let formatters: [DateFormatter] = {
            let utc = TimeZone(secondsFromGMT: 0)
            let locale = Locale(identifier: "en_US_POSIX")
            let formats = [
                "yyyy-MM-dd'T'HH-mm-ss",
                "yyyy-MM-dd'T'HH:mm:ss",
                "yyyy-MM-dd HH:mm:ss",
                "yyyy-MM-dd"
            ]
            return formats.map { format in
                let formatter = DateFormatter()
                formatter.locale = locale
                formatter.timeZone = utc
                formatter.dateFormat = format
                return formatter
            }
        }()

        let patterns = [
            #"(20\d{2}-\d{2}-\d{2}T\d{2}[-:]\d{2}[-:]\d{2})"#,
            #"(20\d{2}-\d{2}-\d{2}\s\d{2}:\d{2}:\d{2})"#,
            #"(20\d{2}-\d{2}-\d{2})"#
        ]

        for candidate in candidates {
            let text = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                guard let match = regex.firstMatch(in: text, options: [], range: range),
                      match.numberOfRanges > 1,
                      let tokenRange = Range(match.range(at: 1), in: text) else {
                    continue
                }

                let token = String(text[tokenRange])
                for formatter in formatters {
                    if let date = formatter.date(from: token) {
                        return date
                    }
                }
            }
        }

        return nil
    }

    private static func inferKind(from relativePath: String, valueHint: String?) -> MemoryEventKind {
        let path = relativePath.lowercased()
        let hint = (valueHint ?? "").lowercased()
        let joined = path + " " + hint

        if joined.contains("rewrite") || joined.contains("rephrase") {
            return .rewrite
        }
        if joined.contains("summary") {
            return .summary
        }
        if joined.contains("plan") || joined.contains("roadmap") || joined.contains("todo") || joined.contains("backlog") {
            return .plan
        }
        if joined.contains("command") || joined.contains("shell") || joined.contains("terminal") {
            return .command
        }
        if joined.contains("edit") || joined.contains("patch") || joined.contains("diff") {
            return .fileEdit
        }
        if joined.contains("chat") || joined.contains("conversation") || joined.contains("message") {
            return .conversation
        }
        if joined.contains("note") || joined.contains("memo") {
            return .note
        }
        return .unknown
    }

    private static func flattenMetadata(from dictionary: [String: Any]) -> [String: String] {
        var flattened: [String: String] = [:]
        flattened.reserveCapacity(min(dictionary.count, 16))

        for (key, value) in dictionary {
            switch value {
            case let string as String:
                let normalized = MemoryTextNormalizer.normalizedBody(string)
                if !normalized.isEmpty && normalized.count <= 400 {
                    flattened[key] = normalized
                }
            case let number as NSNumber:
                flattened[key] = number.stringValue
            case let bool as Bool:
                flattened[key] = bool ? "true" : "false"
            default:
                continue
            }
        }
        return flattened
    }

    private static func shouldSkipLowSignalDictionary(_ dictionary: [String: Any]) -> Bool {
        guard !dictionary.isEmpty else { return true }

        let keySet = Set(dictionary.keys.map { $0.lowercased() })
        let lowSignalKeys: Set<String> = [
            "workspace", "workspaceid", "folder", "path", "uri", "id", "hash",
            "updatedat", "createdat", "timestamp", "version", "windowid",
            "machineid", "state", "storage", "lastopened", "mtime", "ctime",
            "project", "repository", "repo", "branch", "language"
        ]
        let hasMostlyLowSignalKeys = !keySet.isEmpty && keySet.subtracting(lowSignalKeys).count <= 2

        var longTextFieldCount = 0
        for value in dictionary.values {
            if let text = value as? String {
                let normalized = MemoryTextNormalizer.normalizedBody(text)
                if normalized.count >= 28 && normalized.contains(where: \.isWhitespace) {
                    longTextFieldCount += 1
                }
            }
        }

        if hasMostlyLowSignalKeys && longTextFieldCount == 0 {
            return true
        }

        if longTextFieldCount == 0,
           dictionary.values.allSatisfy({ value in
               value is NSNumber || value is Bool || value is NSNull || (value as? String)?.count ?? 0 < 24
           }) {
            return true
        }

        return false
    }

    private static func serializeJSON(dictionary: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return ""
        }
        return json
    }

    private static func fileStem(from relativePath: String) -> String {
        URL(fileURLWithPath: relativePath).deletingPathExtension().lastPathComponent
    }

    private static func markdownSections(from text: String) -> [(title: String, body: String)] {
        var sections: [(title: String, body: String)] = []
        var currentTitle = "Section"
        var currentBodyLines: [String] = []

        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                if !currentBodyLines.joined().isEmpty {
                    let body = MemoryTextNormalizer.normalizedBody(currentBodyLines.joined(separator: "\n"))
                    if !body.isEmpty {
                        sections.append((currentTitle, body))
                    }
                }
                currentTitle = MemoryTextNormalizer.normalizedTitle(
                    trimmed.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces),
                    fallback: "Section"
                )
                currentBodyLines = []
            } else {
                currentBodyLines.append(line)
            }
        }

        let trailingBody = MemoryTextNormalizer.normalizedBody(currentBodyLines.joined(separator: "\n"))
        if !trailingBody.isEmpty {
            sections.append((currentTitle, trailingBody))
        }
        return sections
    }
}

private struct GenericMemorySourceAdapter: MemorySourceAdapter {
    let provider: MemoryProviderKind
    let maxFileSizeBytes: Int64
    let allowedFileExtensions: Set<String>

    init(
        provider: MemoryProviderKind,
        maxFileSizeBytes: Int64 = 2_500_000,
        allowedFileExtensions: Set<String> = ["jsonl", "ndjson", "json"]
    ) {
        self.provider = provider
        self.maxFileSizeBytes = maxFileSizeBytes
        self.allowedFileExtensions = allowedFileExtensions
    }

    func discoverFiles(
        in rootURL: URL,
        fileManager: FileManager,
        maxFiles: Int
    ) -> [URL] {
        MemoryAdapterFileDiscovery.discoverFiles(
            in: rootURL,
            fileManager: fileManager,
            allowedFileExtensions: allowedFileExtensions,
            maxFileSizeBytes: maxFileSizeBytes,
            maxFiles: maxFiles
        )
    }

    func parse(
        fileURL: URL,
        relativePath: String,
        fileManager: FileManager
    ) throws -> [MemoryEventDraft] {
        try MemoryAdapterEventParser.parseFile(
            provider: provider,
            fileURL: fileURL,
            relativePath: relativePath,
            fileManager: fileManager
        )
    }
}

struct CodexMemorySourceAdapter: MemorySourceAdapter {
    private let base = GenericMemorySourceAdapter(provider: .codex)
    var provider: MemoryProviderKind { base.provider }
    var maxFileSizeBytes: Int64 { base.maxFileSizeBytes }
    var allowedFileExtensions: Set<String> { base.allowedFileExtensions }
    func discoverFiles(in rootURL: URL, fileManager: FileManager, maxFiles: Int) -> [URL] {
        base.discoverFiles(in: rootURL, fileManager: fileManager, maxFiles: maxFiles)
    }
    func parse(fileURL: URL, relativePath: String, fileManager: FileManager) throws -> [MemoryEventDraft] {
        try base.parse(fileURL: fileURL, relativePath: relativePath, fileManager: fileManager)
    }
}

struct OpenCodeMemorySourceAdapter: MemorySourceAdapter {
    private let base = GenericMemorySourceAdapter(provider: .opencode)
    var provider: MemoryProviderKind { base.provider }
    var maxFileSizeBytes: Int64 { base.maxFileSizeBytes }
    var allowedFileExtensions: Set<String> { base.allowedFileExtensions }
    func discoverFiles(in rootURL: URL, fileManager: FileManager, maxFiles: Int) -> [URL] {
        base.discoverFiles(in: rootURL, fileManager: fileManager, maxFiles: maxFiles)
    }
    func parse(fileURL: URL, relativePath: String, fileManager: FileManager) throws -> [MemoryEventDraft] {
        try base.parse(fileURL: fileURL, relativePath: relativePath, fileManager: fileManager)
    }
}

struct ClaudeMemorySourceAdapter: MemorySourceAdapter {
    private let base = GenericMemorySourceAdapter(provider: .claude)
    var provider: MemoryProviderKind { base.provider }
    var maxFileSizeBytes: Int64 { base.maxFileSizeBytes }
    var allowedFileExtensions: Set<String> { base.allowedFileExtensions }
    func discoverFiles(in rootURL: URL, fileManager: FileManager, maxFiles: Int) -> [URL] {
        base.discoverFiles(in: rootURL, fileManager: fileManager, maxFiles: maxFiles)
    }
    func parse(fileURL: URL, relativePath: String, fileManager: FileManager) throws -> [MemoryEventDraft] {
        try base.parse(fileURL: fileURL, relativePath: relativePath, fileManager: fileManager)
    }
}

struct CopilotMemorySourceAdapter: MemorySourceAdapter {
    private let base = GenericMemorySourceAdapter(provider: .copilot)
    var provider: MemoryProviderKind { base.provider }
    var maxFileSizeBytes: Int64 { base.maxFileSizeBytes }
    var allowedFileExtensions: Set<String> { base.allowedFileExtensions }
    func discoverFiles(in rootURL: URL, fileManager: FileManager, maxFiles: Int) -> [URL] {
        base.discoverFiles(in: rootURL, fileManager: fileManager, maxFiles: maxFiles)
    }
    func parse(fileURL: URL, relativePath: String, fileManager: FileManager) throws -> [MemoryEventDraft] {
        try base.parse(fileURL: fileURL, relativePath: relativePath, fileManager: fileManager)
    }
}

struct CursorMemorySourceAdapter: MemorySourceAdapter {
    private let base = GenericMemorySourceAdapter(provider: .cursor)
    var provider: MemoryProviderKind { base.provider }
    var maxFileSizeBytes: Int64 { base.maxFileSizeBytes }
    var allowedFileExtensions: Set<String> { base.allowedFileExtensions }
    func discoverFiles(in rootURL: URL, fileManager: FileManager, maxFiles: Int) -> [URL] {
        base.discoverFiles(in: rootURL, fileManager: fileManager, maxFiles: maxFiles)
    }
    func parse(fileURL: URL, relativePath: String, fileManager: FileManager) throws -> [MemoryEventDraft] {
        try base.parse(fileURL: fileURL, relativePath: relativePath, fileManager: fileManager)
    }
}

struct KimiMemorySourceAdapter: MemorySourceAdapter {
    private let base = GenericMemorySourceAdapter(provider: .kimi)
    var provider: MemoryProviderKind { base.provider }
    var maxFileSizeBytes: Int64 { base.maxFileSizeBytes }
    var allowedFileExtensions: Set<String> { base.allowedFileExtensions }
    func discoverFiles(in rootURL: URL, fileManager: FileManager, maxFiles: Int) -> [URL] {
        base.discoverFiles(in: rootURL, fileManager: fileManager, maxFiles: maxFiles)
    }
    func parse(fileURL: URL, relativePath: String, fileManager: FileManager) throws -> [MemoryEventDraft] {
        try base.parse(fileURL: fileURL, relativePath: relativePath, fileManager: fileManager)
    }
}

struct GeminiMemorySourceAdapter: MemorySourceAdapter {
    private let base = GenericMemorySourceAdapter(provider: .gemini)
    var provider: MemoryProviderKind { base.provider }
    var maxFileSizeBytes: Int64 { base.maxFileSizeBytes }
    var allowedFileExtensions: Set<String> { base.allowedFileExtensions }
    func discoverFiles(in rootURL: URL, fileManager: FileManager, maxFiles: Int) -> [URL] {
        base.discoverFiles(in: rootURL, fileManager: fileManager, maxFiles: maxFiles)
    }
    func parse(fileURL: URL, relativePath: String, fileManager: FileManager) throws -> [MemoryEventDraft] {
        try base.parse(fileURL: fileURL, relativePath: relativePath, fileManager: fileManager)
    }
}

struct WindsurfMemorySourceAdapter: MemorySourceAdapter {
    private let base = GenericMemorySourceAdapter(provider: .windsurf)
    var provider: MemoryProviderKind { base.provider }
    var maxFileSizeBytes: Int64 { base.maxFileSizeBytes }
    var allowedFileExtensions: Set<String> { base.allowedFileExtensions }
    func discoverFiles(in rootURL: URL, fileManager: FileManager, maxFiles: Int) -> [URL] {
        base.discoverFiles(in: rootURL, fileManager: fileManager, maxFiles: maxFiles)
    }
    func parse(fileURL: URL, relativePath: String, fileManager: FileManager) throws -> [MemoryEventDraft] {
        try base.parse(fileURL: fileURL, relativePath: relativePath, fileManager: fileManager)
    }
}

struct CodeiumMemorySourceAdapter: MemorySourceAdapter {
    private let base = GenericMemorySourceAdapter(provider: .codeium)
    var provider: MemoryProviderKind { base.provider }
    var maxFileSizeBytes: Int64 { base.maxFileSizeBytes }
    var allowedFileExtensions: Set<String> { base.allowedFileExtensions }
    func discoverFiles(in rootURL: URL, fileManager: FileManager, maxFiles: Int) -> [URL] {
        base.discoverFiles(in: rootURL, fileManager: fileManager, maxFiles: maxFiles)
    }
    func parse(fileURL: URL, relativePath: String, fileManager: FileManager) throws -> [MemoryEventDraft] {
        try base.parse(fileURL: fileURL, relativePath: relativePath, fileManager: fileManager)
    }
}
