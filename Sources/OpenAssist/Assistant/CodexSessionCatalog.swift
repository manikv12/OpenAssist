import Foundation

struct CodexSessionCatalog {
    private static let metadataReadLimit = 32 * 1024
    private static let summaryTailReadLimit = 256 * 1024
    private static let recentHistoryTailReadLimit = 384 * 1024
    private static let summaryOverscanLimit = 24
    private static let fractionalSecondsDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let standardDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    let fileManager: FileManager
    let homeDirectory: URL
    private let quickLookCache: SessionQuickLookCache
    private let activityStore: AssistantSessionActivityStore

    private struct SessionIndexRecord {
        let id: String
        var threadName: String?
        var updatedAtRawValue: String?
        var isArchived: Bool
        var archivedAt: Date?
        var archiveExpiresAt: Date?
        var archiveUsesDefaultRetention: Bool?

        var hasArchiveMetadata: Bool {
            isArchived || archivedAt != nil || archiveExpiresAt != nil || archiveUsesDefaultRetention != nil
        }

        var hasMeaningfulMetadata: Bool {
            threadName != nil || hasArchiveMetadata
        }

        func serializedJSON(dateFormatter: (Date) -> String) -> [String: Any] {
            var json: [String: Any] = ["id": id]
            if let threadName {
                json["thread_name"] = threadName
            }
            if let updatedAtRawValue {
                json["updated_at"] = updatedAtRawValue
            }
            if isArchived {
                json["archived"] = true
            }
            if let archivedAt {
                json["archived_at"] = dateFormatter(archivedAt)
            }
            if let archiveExpiresAt {
                json["archive_expires_at"] = dateFormatter(archiveExpiresAt)
            }
            if let archiveUsesDefaultRetention {
                json["archive_uses_default_retention"] = archiveUsesDefaultRetention
            }
            return json
        }
    }

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        activityStore: AssistantSessionActivityStore? = nil
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
        self.quickLookCache = SessionQuickLookCache()
        self.activityStore = activityStore ?? AssistantSessionActivityStore(
            fileManager: fileManager,
            homeDirectory: homeDirectory
        )
    }

    struct SessionHistoryChunk {
        let timeline: [AssistantTimelineItem]
        let transcript: [AssistantTranscriptEntry]
        let hasMoreTimeline: Bool
        let hasMoreTranscript: Bool

        var hasMore: Bool {
            hasMoreTimeline || hasMoreTranscript
        }
    }

    func loadSessions(
        limit: Int = 40,
        preferredThreadID: String? = nil,
        preferredCWD: String? = nil,
        sessionIDs: [String]? = nil,
        originatorFilter: String? = nil
    ) async throws -> [AssistantSessionSummary] {
        let normalizedSessionIDs = normalizedSessionIDSet(from: sessionIDs)
        let files = sessionFiles(matching: normalizedSessionIDs)
        let sessionIndexRecords = loadSessionIndexRecords()
        return loadIndexedSessions(
            from: files,
            limit: limit,
            preferredThreadID: preferredThreadID,
            preferredCWD: preferredCWD,
            originatorFilter: originatorFilter,
            sessionIndexRecords: sessionIndexRecords
        )
    }

    func loadTranscript(sessionID: String, limit: Int = 200) async -> [AssistantTranscriptEntry] {
        loadTranscript(
            sessionID: sessionID,
            limit: limit,
            readLimit: nil
        )
    }

    func loadMergedTimeline(sessionID: String, limit: Int = 400) async -> [AssistantTimelineItem] {
        loadMergedTimeline(
            sessionID: sessionID,
            limit: limit,
            readLimit: nil
        )
    }

    func loadRecentHistoryChunk(
        sessionID: String,
        timelineLimit: Int,
        transcriptLimit: Int
    ) async -> SessionHistoryChunk {
        let sourceMayHaveOlderHistory = (sessionFileRecord(for: sessionID)?.fileSize ?? 0) > Self.recentHistoryTailReadLimit
        async let timelineTask = loadMergedTimeline(
            sessionID: sessionID,
            limit: timelineLimit,
            readLimit: Self.recentHistoryTailReadLimit
        )
        async let transcriptTask = loadTranscript(
            sessionID: sessionID,
            limit: transcriptLimit,
            readLimit: Self.recentHistoryTailReadLimit
        )
        let (timeline, transcript) = await (timelineTask, transcriptTask)
        return SessionHistoryChunk(
            timeline: timeline,
            transcript: transcript,
            hasMoreTimeline: sourceMayHaveOlderHistory || timeline.count >= timelineLimit,
            hasMoreTranscript: sourceMayHaveOlderHistory || transcript.count >= transcriptLimit
        )
    }

    private func loadTranscript(
        sessionID: String,
        limit: Int,
        readLimit: Int?
    ) -> [AssistantTranscriptEntry] {
        guard let sessionID = sessionID.nonEmpty,
              let file = sessionFileRecord(for: sessionID) else {
            return []
        }

        let metadata = loadSessionMetadata(from: file)
        let entries: [AssistantTranscriptEntry]
        if let readLimit,
           file.fileSize > readLimit,
           let trailingContents = readTrailingText(from: file, maxBytes: readLimit)?.nonEmpty {
            let recentContents = normalizedTrailingScanText(
                trailingContents,
                fileSize: file.fileSize,
                readLimit: readLimit
            )
            let recentEntries = parseTranscriptContents(
                from: recentContents,
                fileURL: file.url,
                metadata: metadata
            )
            entries = recentEntries.isEmpty ? parseTranscript(from: file.url) : recentEntries
        } else {
            entries = parseTranscript(from: file.url)
        }

        if entries.count <= limit {
            return entries
        }
        return Array(entries.suffix(limit))
    }

    private func loadMergedTimeline(
        sessionID: String,
        limit: Int,
        readLimit: Int?
    ) -> [AssistantTimelineItem] {
        guard let sessionID = sessionID.nonEmpty else { return [] }

        let codexItems: [AssistantTimelineItem]
        if let file = sessionFileRecord(for: sessionID) {
            let metadata = loadSessionMetadata(from: file)
            if let readLimit,
               file.fileSize > readLimit,
               let trailingContents = readTrailingText(from: file, maxBytes: readLimit)?.nonEmpty {
                let recentContents = normalizedTrailingScanText(
                    trailingContents,
                    fileSize: file.fileSize,
                    readLimit: readLimit
                )
                let recentItems = parseTimelineContents(
                    from: recentContents,
                    fileURL: file.url,
                    metadata: metadata
                )
                codexItems = recentItems.isEmpty ? parseTimeline(from: file.url) : recentItems
            } else {
                codexItems = parseTimeline(from: file.url)
            }
        } else {
            codexItems = []
        }

        let cachedItems = activityStore.loadTimeline(sessionID: sessionID)
        let merged = mergeTimelineItems(codexItems, cachedItems)

        if merged.count <= limit {
            return merged
        }
        return Array(merged.suffix(limit))
    }

    func saveNormalizedTimeline(_ items: [AssistantTimelineItem], for sessionID: String) {
        activityStore.saveTimeline(items, sessionID: sessionID)
    }

    func deleteSession(sessionID: String) async throws -> Bool {
        return try deleteSessionSynchronously(sessionID: sessionID)
    }

    func deleteSessionSynchronously(sessionID: String) throws -> Bool {
        guard let sessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
              let fileURL = sessionFile(for: sessionID) else {
            activityStore.deleteTimeline(sessionID: sessionID)
            try removeSessionIndexRecord(sessionID: sessionID)
            return false
        }

        try fileManager.removeItem(at: fileURL)
        activityStore.deleteTimeline(sessionID: sessionID)
        try removeSessionIndexRecord(sessionID: sessionID)
        removeEmptyParentDirectories(startingAt: fileURL.deletingLastPathComponent())
        return true
    }

    func deleteSessions(sessionIDs: [String]) async throws -> Int {
        let normalizedSessionIDs = normalizedSessionIDSet(from: sessionIDs) ?? []
        guard !normalizedSessionIDs.isEmpty else { return 0 }

        let files = sessionFiles(matching: normalizedSessionIDs)
        var deletedCount = 0
        for file in files {
            do {
                try fileManager.removeItem(at: file.url)
                let deletedSessionID = sessionIDFromFilename(file.url)
                activityStore.deleteTimeline(sessionID: deletedSessionID)
                try removeSessionIndexRecord(sessionID: deletedSessionID)
                deletedCount += 1
                removeEmptyParentDirectories(startingAt: file.url.deletingLastPathComponent())
            } catch {
                throw error
            }
        }

        for sessionID in normalizedSessionIDs where !files.contains(where: { matchesSessionID(in: $0.url, against: Set([sessionID])) }) {
            activityStore.deleteTimeline(sessionID: sessionID)
            try removeSessionIndexRecord(sessionID: sessionID)
        }

        return deletedCount
    }

    func renameSession(sessionID: String, title: String) throws {
        guard let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return
        }
        guard let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return
        }
        try upsertSessionIndexRecord(for: normalizedSessionID) { record in
            record.threadName = normalizedTitle
        }
    }

    func archiveSession(
        sessionID: String,
        archivedAt: Date,
        expiresAt: Date,
        usesDefaultRetention: Bool
    ) throws {
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionID.isEmpty else { return }

        try upsertSessionIndexRecord(for: normalizedSessionID) { record in
            record.isArchived = true
            record.archivedAt = archivedAt
            record.archiveExpiresAt = expiresAt
            record.archiveUsesDefaultRetention = usesDefaultRetention
        }
    }

    func unarchiveSession(sessionID: String) throws {
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionID.isEmpty else { return }

        try upsertSessionIndexRecord(for: normalizedSessionID) { record in
            record.isArchived = false
            record.archivedAt = nil
            record.archiveExpiresAt = nil
            record.archiveUsesDefaultRetention = nil
        }
    }

    func expiredArchivedSessionIDs(asOf referenceDate: Date = Date()) -> [String] {
        loadSessionIndexRecords().values.compactMap { record in
            guard record.isArchived,
                  let archiveExpiresAt = record.archiveExpiresAt,
                  archiveExpiresAt <= referenceDate else {
                return nil
            }
            return record.id
        }
    }

    private var sessionsRoot: URL {
        homeDirectory.appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    private var sessionIndexURL: URL {
        homeDirectory.appendingPathComponent(".codex/session_index.jsonl", isDirectory: false)
    }

    private func sessionFiles(matching sessionIDs: Set<String>? = nil) -> [SessionFileRecord] {
        guard let enumerator = fileManager.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .contentModificationDateKey,
                .fileSizeKey
            ],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [SessionFileRecord] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "jsonl",
                  isRegularFile(url) else {
                continue
            }
            if let sessionIDs,
               !sessionIDs.isEmpty,
               !matchesSessionID(in: url, against: sessionIDs) {
                continue
            }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            files.append(
                SessionFileRecord(
                    url: url,
                    modificationDate: values?.contentModificationDate,
                    fileSize: values?.fileSize ?? 0
                )
            )
        }
        return files.sorted {
            compareSessionFileRecency($0, $1)
        }
    }

    private func sessionFile(for sessionID: String) -> URL? {
        sessionFileRecord(for: sessionID)?.url
    }

    func sessionFileURL(for sessionID: String) -> URL? {
        sessionFile(for: sessionID)
    }

    private func sessionFileRecord(for sessionID: String) -> SessionFileRecord? {
        let trimmedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSessionID.isEmpty else { return nil }

        let files = sessionFiles(matching: Set([trimmedSessionID]))
        if let filenameMatch = files.first(where: { $0.url.lastPathComponent.contains(sessionID) }) {
            return filenameMatch
        }

        return files.first {
            loadSessionMetadata(from: $0)?.id == sessionID
        }
    }

    private func normalizedSessionIDSet(from rawValues: [String]?) -> Set<String>? {
        guard let rawValues else { return nil }
        let normalized = Set(
            rawValues.compactMap {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            }
        )
        return normalized
    }

    private func matchesSessionID(in fileURL: URL, against sessionIDs: Set<String>) -> Bool {
        let filename = fileURL.lastPathComponent.lowercased()
        let derivedID = sessionIDFromFilename(fileURL).lowercased()

        for sessionID in sessionIDs {
            let normalized = sessionID.lowercased()
            if derivedID == normalized || filename.contains(normalized) {
                return true
            }
        }

        return false
    }

    private func removeEmptyParentDirectories(startingAt directoryURL: URL) {
        var currentDirectory = directoryURL
        let sessionsRootPath = sessionsRoot.standardizedFileURL.path

        while currentDirectory.standardizedFileURL.path.hasPrefix(sessionsRootPath),
              currentDirectory.standardizedFileURL.path != sessionsRootPath {
            do {
                let contents = try fileManager.contentsOfDirectory(atPath: currentDirectory.path)
                guard contents.isEmpty else { break }
                try fileManager.removeItem(at: currentDirectory)
                currentDirectory.deleteLastPathComponent()
            } catch {
                break
            }
        }
    }

    private func loadIndexedSessions(
        from files: [SessionFileRecord],
        limit: Int,
        preferredThreadID: String?,
        preferredCWD: String?,
        originatorFilter: String?,
        sessionIndexRecords: [String: SessionIndexRecord]
    ) -> [AssistantSessionSummary] {
        var metadataCache: [URL: SessionMetadata] = [:]
        var missingMetadataURLs = Set<URL>()
        func metadata(for file: SessionFileRecord) -> SessionMetadata? {
            if let cached = metadataCache[file.url] {
                return cached
            }
            if missingMetadataURLs.contains(file.url) {
                return nil
            }
            let loaded = loadSessionMetadata(from: file)
            if let loaded {
                metadataCache[file.url] = loaded
            } else {
                missingMetadataURLs.insert(file.url)
            }
            return loaded
        }

        var candidateFiles = files
        if let normalizedOriginator = originatorFilter?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            let preferredNormalizedCWD = normalizedCWD(preferredCWD)
            let preferredNormalizedThreadID = preferredThreadID?.lowercased()
            let targetCount = max(limit + Self.summaryOverscanLimit, limit * 2)
            var filtered: [SessionFileRecord] = []
            var preferredThreadCandidate: SessionFileRecord?
            var preferredCWDCandidate: SessionFileRecord?

            for file in files {
                let metadata = metadata(for: file)

                if preferredThreadCandidate == nil,
                   matchesPreferredThread(file, metadata: metadata, preferredThreadID: preferredNormalizedThreadID) {
                    preferredThreadCandidate = file
                }

                if preferredCWDCandidate == nil,
                   normalizedCWD(metadata?.cwd) == preferredNormalizedCWD {
                    preferredCWDCandidate = file
                }

                guard metadata?.matchesOriginator(normalizedOriginator) == true else {
                    continue
                }

                filtered.append(file)

                let hasPreferredThread = preferredNormalizedThreadID == nil || preferredThreadCandidate != nil
                let hasPreferredCWD = preferredNormalizedCWD == nil || preferredCWDCandidate != nil
                if filtered.count >= targetCount && hasPreferredThread && hasPreferredCWD {
                    break
                }
            }

            if let preferredThreadCandidate,
               !filtered.contains(where: { $0.url == preferredThreadCandidate.url }),
               metadata(for: preferredThreadCandidate)?.matchesOriginator(normalizedOriginator) == true {
                filtered.append(preferredThreadCandidate)
            }

            if let preferredCWDCandidate,
               !filtered.contains(where: { $0.url == preferredCWDCandidate.url }),
               metadata(for: preferredCWDCandidate)?.matchesOriginator(normalizedOriginator) == true {
                filtered.append(preferredCWDCandidate)
            }

            candidateFiles = filtered
        }

        let summaries = candidateFiles.compactMap { file in
            parseSessionSummary(
                from: file,
                originatorFilter: originatorFilter,
                metadata: metadata(for: file)
            ).map { summary in
                applyingSessionIndexRecord(
                    summary,
                    record: sessionIndexRecords[summary.id.lowercased()]
                )
            }
        }

        let sorted = summaries.sorted {
            compareSessions(
                $0,
                $1,
                preferredThreadID: preferredThreadID,
                preferredCWD: preferredCWD
            )
        }
        return Array(sorted.prefix(limit))
    }

    private func parseSessionSummary(
        from file: SessionFileRecord,
        originatorFilter: String?,
        metadata: SessionMetadata? = nil
    ) -> AssistantSessionSummary? {
        let resolvedMetadata = metadata ?? loadSessionMetadata(from: file)
        if let cached = quickLookCache.summary(for: file) {
            if let normalizedOriginator = originatorFilter?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
                return resolvedMetadata?.matchesOriginator(normalizedOriginator) == true ? cached : nil
            }
            return cached
        }

        switch quickSessionSummary(
            from: file,
            originatorFilter: originatorFilter,
            metadata: resolvedMetadata
        ) {
        case let .summary(summary):
            quickLookCache.store(summary: summary, metadata: resolvedMetadata, for: file)
            return summary
        case .filteredOut:
            return nil
        case .needsFullParse:
            let summary = parseSessionSummaryFull(
                from: file.url,
                originatorFilter: originatorFilter,
                fallbackUpdatedAt: file.modificationDate,
                metadata: resolvedMetadata
            )
            if let summary {
                quickLookCache.store(summary: summary, metadata: resolvedMetadata, for: file)
            }
            return summary
        }
    }

    private func parseSessionSummaryFull(
        from fileURL: URL,
        originatorFilter: String?,
        fallbackUpdatedAt: Date?,
        metadata: SessionMetadata? = nil
    ) -> AssistantSessionSummary? {
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return nil
        }

        return parseSessionSummaryContents(
            from: contents,
            fileURL: fileURL,
            originatorFilter: originatorFilter,
            fallbackUpdatedAt: fallbackUpdatedAt,
            metadata: metadata
        )
    }

    private func quickSessionSummary(
        from file: SessionFileRecord,
        originatorFilter: String?,
        metadata prefetchedMetadata: SessionMetadata?
    ) -> QuickSessionSummaryResult {
        let resolvedMetadata = prefetchedMetadata ?? loadSessionMetadata(from: file)
        if let normalizedOriginator = originatorFilter?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            guard resolvedMetadata?.matchesOriginator(normalizedOriginator) == true else {
                return .filteredOut
            }
        }

        guard let resolvedMetadata else {
            return .needsFullParse
        }

        guard let trailingContents = readTrailingText(from: file),
              !trailingContents.isEmpty else {
            return .needsFullParse
        }

        let recentContents = normalizedTrailingScanText(
            trailingContents,
            fileSize: file.fileSize
        )
        var accumulator = SessionSummaryAccumulator()
        scanSessionSummaryLines(
            in: recentContents,
            metadataCreatedAt: resolvedMetadata.createdAt,
            accumulator: &accumulator
        )
        if accumulator.updatedAt == nil {
            accumulator.updatedAt = file.modificationDate
        }

        if file.fileSize > Self.summaryTailReadLimit,
           !accumulator.hasRelevantTailContent {
            return .needsFullParse
        }

        return .summary(
            buildSessionSummary(
                fileURL: file.url,
                metadata: resolvedMetadata,
                accumulator: accumulator
            )
        )
    }

    private func parseSessionSummaryContents(
        from contents: String,
        fileURL: URL,
        originatorFilter: String?,
        fallbackUpdatedAt: Date?,
        metadata prefetchedMetadata: SessionMetadata? = nil
    ) -> AssistantSessionSummary? {
        let fallbackID = sessionIDFromFilename(fileURL)
        var metadata = prefetchedMetadata ?? parsePrimaryMetadata(from: contents, fileURL: fileURL)
        if let originatorFilter = originatorFilter?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            guard metadata?.matchesOriginator(originatorFilter) == true else {
                return nil
            }
        }
        if metadata == nil {
            metadata = SessionMetadata(
                id: fallbackID,
                source: .other,
                parentThreadID: nil,
                cwd: nil,
                createdAt: nil,
                originator: nil
            )
        }

        var accumulator = SessionSummaryAccumulator()
        scanSessionSummaryLines(
            in: contents,
            metadataCreatedAt: metadata?.createdAt,
            accumulator: &accumulator
        )
        if accumulator.updatedAt == nil {
            accumulator.updatedAt = fallbackUpdatedAt
        }

        return buildSessionSummary(
            fileURL: fileURL,
            metadata: metadata,
            accumulator: accumulator
        )
    }

    private func buildSessionSummary(
        fileURL: URL,
        metadata: SessionMetadata?,
        accumulator: SessionSummaryAccumulator
    ) -> AssistantSessionSummary {
        let fallbackID = sessionIDFromFilename(fileURL)
        let latestUserText = cleanSummaryText(accumulator.latestUser?.text ?? accumulator.fallbackUser?.text)
        let latestAssistantText = cleanSummaryText(accumulator.latestAssistant?.text ?? accumulator.fallbackAssistant?.text)
        let title = truncate(
            preferredSessionTitle(
                latestUserMessage: latestUserText,
                latestAssistantMessage: latestAssistantText,
                cwd: metadata?.cwd
            ),
            limit: 84
        ) ?? "Codex Session"

        return AssistantSessionSummary(
            id: metadata?.id ?? fallbackID,
            title: title,
            source: metadata?.source ?? .other,
            status: accumulator.explicitStatus ?? inferredStatus(
                latestUserMessage: latestUserText,
                latestAssistantMessage: latestAssistantText
            ),
            parentThreadID: metadata?.parentThreadID,
            cwd: metadata?.cwd,
            createdAt: metadata?.createdAt,
            updatedAt: accumulator.updatedAt ?? metadata?.createdAt,
            summary: nil,
            latestModel: accumulator.latestModel,
            latestInteractionMode: accumulator.latestInteractionMode,
            latestReasoningEffort: accumulator.latestReasoningEffort,
            latestServiceTier: accumulator.latestServiceTier,
            latestUserMessage: truncate(latestUserText, limit: 220),
            latestAssistantMessage: truncate(latestAssistantText, limit: 280)
        )
    }

    private func scanSessionSummaryLines(
        in contents: String,
        metadataCreatedAt: Date?,
        accumulator: inout SessionSummaryAccumulator
    ) {
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            guard let json = jsonObject(from: rawLine) else {
                continue
            }

            let lineTimestamp = parseDate(stringValue(json["timestamp"]))
            accumulator.updatedAt = maxDate(accumulator.updatedAt, lineTimestamp)

            switch stringValue(json["type"]) {
            case "turn_context":
                if let payload = dictionaryValue(json["payload"]) {
                    let collaborationMode = dictionaryValue(payload["collaboration_mode"])
                        ?? dictionaryValue(payload["collaborationMode"])
                    let collaborationSettings = collaborationMode.flatMap { mode in
                        dictionaryValue(mode["settings"])
                    }

                    if let model = firstNonEmptyString(
                        stringValue(payload["model"]),
                        collaborationSettings.flatMap { stringValue($0["model"]) }
                    ) {
                        accumulator.latestModel = model
                    }

                    if let mode = sessionInteractionMode(
                        collaborationMode: collaborationMode,
                        approvalPolicy: stringValue(payload["approval_policy"]) ?? stringValue(payload["approvalPolicy"]),
                        sandboxPolicy: dictionaryValue(payload["sandbox_policy"]) ?? dictionaryValue(payload["sandboxPolicy"])
                    ) {
                        accumulator.latestInteractionMode = mode
                    }

                    if let effort = firstNonEmptyString(
                        collaborationSettings.flatMap { stringValue($0["reasoning_effort"]) },
                        collaborationSettings.flatMap { stringValue($0["reasoningEffort"]) },
                        stringValue(payload["reasoning_effort"]),
                        stringValue(payload["reasoningEffort"])
                    ).flatMap(AssistantReasoningEffort.init(rawValue:)) {
                        accumulator.latestReasoningEffort = effort
                    }

                    if let serviceTier = firstNonEmptyString(
                        stringValue(payload["service_tier"]),
                        stringValue(payload["serviceTier"]),
                        collaborationSettings.flatMap { stringValue($0["service_tier"]) },
                        collaborationSettings.flatMap { stringValue($0["serviceTier"]) }
                    ) {
                        accumulator.latestServiceTier = serviceTier
                    }
                }

            case "response_item":
                guard let payload = dictionaryValue(json["payload"]),
                      stringValue(payload["type"]) == "message" else {
                    continue
                }

                let role = stringValue(payload["role"])?.lowercased()
                let rawText = extractMessageText(from: payload["content"])
                let snapshotDate = lineTimestamp ?? metadataCreatedAt

                switch role {
                case "user":
                    if let text = cleanedUserMessage(rawText) {
                        accumulator.latestUser = SessionTextSnapshot(text: text, date: snapshotDate)
                    }
                case "assistant":
                    if let text = cleanedAssistantMessage(rawText) {
                        accumulator.latestAssistant = SessionTextSnapshot(text: text, date: snapshotDate)
                    }
                default:
                    break
                }

            case "event_msg":
                guard let payload = dictionaryValue(json["payload"]) else {
                    continue
                }

                let eventType = stringValue(payload["type"])?.lowercased()
                let snapshotDate = lineTimestamp ?? metadataCreatedAt

                switch eventType {
                case "user_message":
                    if let text = cleanedUserMessage(stringValue(payload["message"])) {
                        accumulator.fallbackUser = SessionTextSnapshot(text: text, date: snapshotDate)
                    }
                case "agent_message":
                    if let text = cleanedAssistantMessage(stringValue(payload["message"])) {
                        accumulator.fallbackAssistant = SessionTextSnapshot(text: text, date: snapshotDate)
                    }
                case "task_started":
                    accumulator.explicitStatus = .active
                case "task_complete":
                    accumulator.explicitStatus = .completed
                    if let text = cleanedAssistantMessage(stringValue(payload["last_agent_message"])) {
                        accumulator.fallbackAssistant = SessionTextSnapshot(text: text, date: snapshotDate)
                    }
                case "approval_request", "permission_request":
                    accumulator.explicitStatus = .waitingForApproval
                case "input_request", "user_input_request":
                    accumulator.explicitStatus = .waitingForInput
                case "turn_aborted":
                    let reason = stringValue(payload["reason"])?.lowercased()
                    accumulator.explicitStatus = reason == "interrupted" ? .idle : .failed
                case "error", "task_failed":
                    accumulator.explicitStatus = .failed
                default:
                    break
                }

            default:
                break
            }
        }
    }

    private func loadSessionMetadata(from file: SessionFileRecord) -> SessionMetadata? {
        switch quickLookCache.metadataLookup(for: file) {
        case let .hit(metadata):
            return metadata
        case .miss:
            break
        }

        guard let leadingText = readLeadingText(from: file.url, maxBytes: Self.metadataReadLimit) else {
            quickLookCache.store(metadata: nil, for: file)
            return nil
        }

        let metadata = parsePrimaryMetadata(from: leadingText, fileURL: file.url)
        quickLookCache.store(metadata: metadata, for: file)
        return metadata
    }

    private func readLeadingText(from fileURL: URL, maxBytes: Int) -> String? {
        guard maxBytes > 0 else { return nil }

        do {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            guard let data = try handle.read(upToCount: maxBytes),
                  !data.isEmpty else {
                return nil
            }
            return String(decoding: data, as: UTF8.self)
        } catch {
            return nil
        }
    }

    private func readTrailingText(from file: SessionFileRecord) -> String? {
        readTrailingText(from: file, maxBytes: Self.summaryTailReadLimit)
    }

    private func readTrailingText(from file: SessionFileRecord, maxBytes: Int) -> String? {
        let normalizedMaxBytes = max(1, maxBytes)
        let readCount = min(max(file.fileSize, 0), normalizedMaxBytes)
        guard readCount > 0 else { return nil }

        do {
            let handle = try FileHandle(forReadingFrom: file.url)
            defer { try? handle.close() }

            if file.fileSize > readCount {
                try handle.seek(toOffset: UInt64(file.fileSize - readCount))
            }

            guard let data = try handle.read(upToCount: readCount),
                  !data.isEmpty else {
                return nil
            }

            return String(decoding: data, as: UTF8.self)
        } catch {
            return nil
        }
    }

    private func normalizedTrailingScanText(_ rawValue: String, fileSize: Int) -> String {
        normalizedTrailingScanText(
            rawValue,
            fileSize: fileSize,
            readLimit: Self.summaryTailReadLimit
        )
    }

    private func normalizedTrailingScanText(_ rawValue: String, fileSize: Int, readLimit: Int) -> String {
        guard fileSize > readLimit else {
            return rawValue
        }

        guard let firstNewline = rawValue.firstIndex(of: "\n") else {
            return ""
        }

        return String(rawValue[rawValue.index(after: firstNewline)...])
    }

    private func compareSessionFileRecency(_ lhs: SessionFileRecord, _ rhs: SessionFileRecord) -> Bool {
        let lhsDate = lhs.modificationDate ?? .distantPast
        let rhsDate = rhs.modificationDate ?? .distantPast
        if lhsDate != rhsDate {
            return lhsDate > rhsDate
        }
        return lhs.url.path.localizedStandardCompare(rhs.url.path) == .orderedDescending
    }

    private func matchesPreferredThread(
        _ file: SessionFileRecord,
        metadata: SessionMetadata?,
        preferredThreadID: String?
    ) -> Bool {
        guard let preferredThreadID else { return false }
        let filename = file.url.lastPathComponent.lowercased()
        if sessionIDFromFilename(file.url).lowercased() == preferredThreadID || filename.contains(preferredThreadID) {
            return true
        }
        return metadata?.id.lowercased() == preferredThreadID
    }

    private func parseTranscript(from fileURL: URL) -> [AssistantTranscriptEntry] {
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return []
        }

        return parseTranscriptContents(from: contents, fileURL: fileURL, metadata: nil)
    }

    private func parseTranscriptContents(
        from contents: String,
        fileURL: URL,
        metadata prefetchedMetadata: SessionMetadata? = nil
    ) -> [AssistantTranscriptEntry] {
        let metadata = prefetchedMetadata ?? parsePrimaryMetadata(from: contents, fileURL: fileURL)
        var candidates: [TranscriptCandidate] = []
        var addedSystemEntry = false

        for (index, rawLine) in contents.split(whereSeparator: \.isNewline).enumerated() {
            guard let json = jsonObject(from: rawLine) else {
                continue
            }

            let lineTimestamp = parseDate(stringValue(json["timestamp"])) ?? metadata?.createdAt ?? Date()

            switch stringValue(json["type"]) {
            case "session_meta":
                guard !addedSystemEntry else {
                    continue
                }
                addedSystemEntry = true
                candidates.append(
                    TranscriptCandidate(
                        lineNumber: index,
                        role: .system,
                        text: sessionStartedText(for: metadata?.source ?? .other),
                        createdAt: lineTimestamp,
                        emphasis: true
                    )
                )

            case "response_item":
                guard let payload = dictionaryValue(json["payload"]),
                      stringValue(payload["type"]) == "message" else {
                    continue
                }

                let role = stringValue(payload["role"])?.lowercased()
                let rawText = extractMessageText(from: payload["content"])

                switch role {
                case "user":
                    guard let text = cleanedUserMessage(rawText) else {
                        continue
                    }
                    candidates.append(
                        TranscriptCandidate(
                            lineNumber: index,
                            role: .user,
                            text: text,
                            createdAt: lineTimestamp,
                            emphasis: false
                        )
                    )
                case "assistant":
                    guard let text = cleanedAssistantMessage(rawText) else {
                        continue
                    }
                    candidates.append(
                        TranscriptCandidate(
                            lineNumber: index,
                            role: .assistant,
                            text: text,
                            createdAt: lineTimestamp,
                            emphasis: false
                        )
                    )
                default:
                    break
                }

            case "event_msg":
                guard let payload = dictionaryValue(json["payload"]),
                      let eventType = stringValue(payload["type"])?.lowercased() else {
                    continue
                }

                switch eventType {
                case "user_message":
                    guard let text = cleanedUserMessage(stringValue(payload["message"])) else {
                        continue
                    }
                    candidates.append(
                        TranscriptCandidate(
                            lineNumber: index,
                            role: .user,
                            text: text,
                            createdAt: lineTimestamp,
                            emphasis: false
                        )
                    )
                case "agent_message":
                    guard let text = cleanedAssistantMessage(stringValue(payload["message"])) else {
                        continue
                    }
                    candidates.append(
                        TranscriptCandidate(
                            lineNumber: index,
                            role: .assistant,
                            text: text,
                            createdAt: lineTimestamp,
                            emphasis: false
                        )
                    )
                case "task_complete":
                    guard let text = cleanedAssistantMessage(stringValue(payload["last_agent_message"])) else {
                        continue
                    }
                    candidates.append(
                        TranscriptCandidate(
                            lineNumber: index,
                            role: .assistant,
                            text: text,
                            createdAt: lineTimestamp,
                            emphasis: false
                        )
                    )
                case "turn_aborted":
                    let reason = stringValue(payload["reason"])?.lowercased()
                    let role: AssistantTranscriptRole = reason == "interrupted" ? .status : .error
                    let text = reason == "interrupted" ? "Task stopped." : "Task failed."
                    candidates.append(
                        TranscriptCandidate(
                            lineNumber: index,
                            role: role,
                            text: text,
                            createdAt: lineTimestamp,
                            emphasis: role == .error
                        )
                    )
                case "error", "task_failed":
                    let errorText = cleanedAssistantMessage(
                        firstNonEmptyString(
                            stringValue(payload["message"]),
                            stringValue(payload["reason"])
                        )
                    ) ?? "Task failed."
                    candidates.append(
                        TranscriptCandidate(
                            lineNumber: index,
                            role: .error,
                            text: errorText,
                            createdAt: lineTimestamp,
                            emphasis: true
                        )
                    )
                default:
                    break
                }

            default:
                break
            }
        }

        let deduped = deduplicateTranscriptCandidates(candidates)
        return deduped.map {
            AssistantTranscriptEntry(
                role: $0.role,
                text: $0.text,
                createdAt: $0.createdAt,
                emphasis: $0.emphasis
            )
        }
    }

    private func parseTimeline(from fileURL: URL) -> [AssistantTimelineItem] {
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return []
        }

        return parseTimelineContents(from: contents, fileURL: fileURL, metadata: nil)
    }

    private func parseTimelineContents(
        from contents: String,
        fileURL: URL,
        metadata prefetchedMetadata: SessionMetadata? = nil
    ) -> [AssistantTimelineItem] {
        let metadata = prefetchedMetadata ?? parsePrimaryMetadata(from: contents, fileURL: fileURL)
        let sessionID = metadata?.id ?? sessionIDFromFilename(fileURL)
        var items: [AssistantTimelineItem] = []
        var activityIndexByID: [String: Int] = [:]

        for (index, rawLine) in contents.split(whereSeparator: \.isNewline).enumerated() {
            guard let json = jsonObject(from: rawLine) else {
                continue
            }

            let lineTimestamp = parseDate(stringValue(json["timestamp"])) ?? metadata?.createdAt ?? Date()

            switch stringValue(json["type"]) {
            case "response_item":
                guard let payload = dictionaryValue(json["payload"]),
                      let payloadType = stringValue(payload["type"])?.lowercased() else {
                    continue
                }

                switch payloadType {
                case "message":
                    let role = stringValue(payload["role"])?.lowercased()
                    let rawText = extractMessageText(from: payload["content"])

                    switch role {
                    case "user":
                        let text = cleanedUserMessage(rawText)
                        let imageAttachments = extractImageAttachments(from: payload["content"])
                        guard text != nil || !imageAttachments.isEmpty else { continue }
                        appendTimelineMessage(
                            .userMessage(
                                id: "codex-user-\(index)",
                                sessionID: sessionID,
                                text: text ?? "",
                                createdAt: lineTimestamp,
                                imageAttachments: imageAttachments.isEmpty ? nil : imageAttachments,
                                source: .codexSession
                            ),
                            to: &items
                        )
                    case "assistant":
                        guard let text = cleanedAssistantMessage(rawText) else { continue }
                        appendTimelineMessage(
                            .assistantFinal(
                                id: "codex-assistant-\(index)",
                                sessionID: sessionID,
                                text: text,
                                createdAt: lineTimestamp,
                                updatedAt: lineTimestamp,
                                isStreaming: false,
                                source: .codexSession
                            ),
                            to: &items
                        )
                    default:
                        break
                    }

                case "function_call":
                    guard let activity = savedFunctionCallActivity(
                        payload: payload,
                        sessionID: sessionID,
                        timestamp: lineTimestamp
                    ) else { continue }
                    upsertTimelineActivity(activity, items: &items, activityIndexByID: &activityIndexByID)

                case "function_call_output":
                    updateTimelineActivityOutput(
                        callID: firstNonEmptyString(
                            stringValue(payload["call_id"]),
                            stringValue(payload["callId"])
                        ) ?? "function-output-\(index)",
                        kind: .commandExecution,
                        title: "Command",
                        friendlySummary: "Ran a terminal command.",
                        rawDetails: decodeSavedOutput(payload["output"]),
                        status: .completed,
                        sessionID: sessionID,
                        timestamp: lineTimestamp,
                        items: &items,
                        activityIndexByID: &activityIndexByID
                    )
                    appendSavedActivityImagePreviewIfNeeded(
                        callID: firstNonEmptyString(
                            stringValue(payload["call_id"]),
                            stringValue(payload["callId"])
                        ) ?? "function-output-\(index)",
                        sessionCWD: metadata?.cwd,
                        timestamp: lineTimestamp,
                        items: &items,
                        activityIndexByID: activityIndexByID
                    )

                case "custom_tool_call":
                    guard let activity = savedCustomToolActivity(
                        payload: payload,
                        sessionID: sessionID,
                        timestamp: lineTimestamp
                    ) else { continue }
                    upsertTimelineActivity(activity, items: &items, activityIndexByID: &activityIndexByID)

                case "custom_tool_call_output":
                    let callID = firstNonEmptyString(
                        stringValue(payload["call_id"]),
                        stringValue(payload["callId"])
                    ) ?? "custom-tool-output-\(index)"
                    let rawOutput = decodeSavedOutput(payload["output"])
                    let existingActivity = activityIndexByID[callID].flatMap { index in
                        items[index].activity
                    }
                    let payloadToolName = stringValue(payload["name"])
                    let kind: AssistantActivityKind
                    if let existingActivity {
                        kind = existingActivity.kind
                    } else if payloadToolName?.lowercased() == "apply_patch" {
                        kind = .fileChange
                    } else {
                        kind = .dynamicToolCall
                    }
                    let title = existingActivity?.title
                        ?? formattedToolTitle(from: payloadToolName)
                        ?? "Tool"
                    let summary = existingActivity?.friendlySummary
                        ?? savedActivitySummary(kind: kind, title: title)

                    updateTimelineActivityOutput(
                        callID: callID,
                        kind: kind,
                        title: title,
                        friendlySummary: summary,
                        rawDetails: rawOutput,
                        status: .completed,
                        sessionID: sessionID,
                        timestamp: lineTimestamp,
                        items: &items,
                        activityIndexByID: &activityIndexByID
                    )
                    let imageAttachments = extractImageAttachments(from: payload["output"])
                    if !imageAttachments.isEmpty {
                        let imageTitle = title == "Image Generation"
                            ? "Generated image"
                            : "Images from \(title)"
                        appendTimelineMessage(
                            .system(
                                id: "saved-tool-image-\(callID)",
                                sessionID: sessionID,
                                turnID: existingActivity?.turnID,
                                text: imageTitle,
                                createdAt: lineTimestamp,
                                imageAttachments: imageAttachments,
                                source: .codexSession
                            ),
                            to: &items
                        )
                    }
                    appendSavedActivityImagePreviewIfNeeded(
                        callID: callID,
                        sessionCWD: metadata?.cwd,
                        timestamp: lineTimestamp,
                        items: &items,
                        activityIndexByID: activityIndexByID
                    )

                case "web_search_call":
                    let query = firstNonEmptyString(
                        stringValue((dictionaryValue(payload["action"]))?["query"]),
                        stringValue(payload["query"])
                    )
                    let activity = AssistantActivityItem(
                        id: firstNonEmptyString(
                            stringValue(payload["id"]),
                            stringValue(payload["call_id"]),
                            "web-search-\(index)"
                        ) ?? "web-search-\(index)",
                        sessionID: sessionID,
                        turnID: nil,
                        kind: .webSearch,
                        title: "Web Search",
                        status: savedActivityStatus(from: stringValue(payload["status"]), default: .completed),
                        friendlySummary: "Searched the web.",
                        rawDetails: truncatedTimelineDetail(query),
                        startedAt: lineTimestamp,
                        updatedAt: lineTimestamp,
                        source: .codexSession
                    )
                    upsertTimelineActivity(activity, items: &items, activityIndexByID: &activityIndexByID)

                default:
                    break
                }

            case "event_msg":
                guard let payload = dictionaryValue(json["payload"]),
                      let eventType = stringValue(payload["type"])?.lowercased() else {
                    continue
                }

                switch eventType {
                case "user_message":
                    let text = cleanedUserMessage(stringValue(payload["message"]))
                    let imageAttachments = extractImageAttachments(from: payload["images"])
                    guard text != nil || !imageAttachments.isEmpty else { continue }
                    appendTimelineMessage(
                        .userMessage(
                            id: "event-user-\(index)",
                            sessionID: sessionID,
                            text: text ?? "",
                            createdAt: lineTimestamp,
                            imageAttachments: imageAttachments.isEmpty ? nil : imageAttachments,
                            source: .codexSession
                        ),
                        to: &items
                    )

                case "agent_message":
                    guard let text = cleanedAssistantMessage(stringValue(payload["message"])) else { continue }
                    let phase = stringValue(payload["phase"])?.lowercased()
                    let isCommentary = phase == "commentary"
                    appendTimelineMessage(
                        isCommentary
                            ? .assistantProgress(
                                id: "event-agent-\(index)",
                                sessionID: sessionID,
                                text: text,
                                createdAt: lineTimestamp,
                                updatedAt: lineTimestamp,
                                isStreaming: false,
                                source: .codexSession
                            )
                            : .assistantFinal(
                                id: "event-agent-\(index)",
                                sessionID: sessionID,
                                text: text,
                                createdAt: lineTimestamp,
                                updatedAt: lineTimestamp,
                                isStreaming: false,
                                source: .codexSession
                            ),
                        to: &items
                    )

                case "task_complete":
                    guard let text = cleanedAssistantMessage(stringValue(payload["last_agent_message"])) else {
                        continue
                    }
                    let completedTurnID = firstNonEmptyString(
                        stringValue(payload["turn_id"]),
                        stringValue(payload["turnID"])
                    )
                    appendTimelineMessage(
                        .assistantFinal(
                            id: "task-complete-\(index)",
                            sessionID: sessionID,
                            turnID: completedTurnID,
                            text: text,
                            createdAt: lineTimestamp,
                            updatedAt: lineTimestamp,
                            isStreaming: false,
                            source: .codexSession
                        ),
                        to: &items
                    )

                case "approval_request", "permission_request":
                    let request = AssistantPermissionRequest(
                        id: index,
                        sessionID: sessionID,
                        toolTitle: firstNonEmptyString(
                            stringValue(payload["tool"]),
                            stringValue(payload["title"]),
                            "Permission needed"
                        ) ?? "Permission needed",
                        toolKind: stringValue(payload["tool_kind"]),
                        rationale: firstNonEmptyString(
                            stringValue(payload["reason"]),
                            stringValue(payload["message"])
                        ),
                        options: [],
                        rawPayloadSummary: extractString(payload["details"])
                    )
                    appendTimelineMessage(
                        .permission(
                            id: "permission-\(index)",
                            sessionID: sessionID,
                            request: request,
                            createdAt: lineTimestamp,
                            source: .codexSession
                        ),
                        to: &items
                    )

                case "input_request", "user_input_request":
                    let request = AssistantPermissionRequest(
                        id: index,
                        sessionID: sessionID,
                        toolTitle: "User input needed",
                        toolKind: "userInput",
                        rationale: firstNonEmptyString(
                            stringValue(payload["message"]),
                            stringValue(payload["question"])
                        ),
                        options: [],
                        rawPayloadSummary: nil
                    )
                    appendTimelineMessage(
                        .permission(
                            id: "user-input-\(index)",
                            sessionID: sessionID,
                            request: request,
                            createdAt: lineTimestamp,
                            source: .codexSession
                        ),
                        to: &items
                    )

                case "turn_aborted":
                    let reason = stringValue(payload["reason"])?.lowercased()
                    appendTimelineMessage(
                        .system(
                            id: "turn-aborted-\(index)",
                            sessionID: sessionID,
                            text: reason == "interrupted" ? "Task stopped." : "Task failed.",
                            createdAt: lineTimestamp,
                            emphasis: reason != "interrupted",
                            source: .codexSession
                        ),
                        to: &items
                    )

                case "error", "task_failed":
                    appendTimelineMessage(
                        .system(
                            id: "event-error-\(index)",
                            sessionID: sessionID,
                            text: cleanedAssistantMessage(
                                firstNonEmptyString(
                                    stringValue(payload["message"]),
                                    stringValue(payload["reason"])
                                )
                            ) ?? "Task failed.",
                            createdAt: lineTimestamp,
                            emphasis: true,
                            source: .codexSession
                        ),
                        to: &items
                    )

                default:
                    break
                }

            default:
                break
            }
        }

        return items.sorted {
            if $0.sortDate != $1.sortDate {
                return $0.sortDate < $1.sortDate
            }
            if $0.lastUpdatedAt != $1.lastUpdatedAt {
                return $0.lastUpdatedAt < $1.lastUpdatedAt
            }
            return $0.id < $1.id
        }
    }

    private func mergeTimelineItems(
        _ primary: [AssistantTimelineItem],
        _ cached: [AssistantTimelineItem]
    ) -> [AssistantTimelineItem] {
        var merged = primary
        var indices = Dictionary(uniqueKeysWithValues: merged.enumerated().map { ($0.element.id, $0.offset) })

        for item in cached {
            if let existingIndex = indices[item.id] {
                merged[existingIndex] = mergeTimelineItem(primary: merged[existingIndex], cached: item)
                continue
            }

            if let duplicateIndex = merged.lastIndex(where: { timelineItemsShouldDeduplicate($0, item) }) {
                merged[duplicateIndex] = mergeTimelineItem(primary: merged[duplicateIndex], cached: item)
                continue
            }

            indices[item.id] = merged.count
            merged.append(item)
        }

        return merged.sorted {
            if $0.sortDate != $1.sortDate {
                return $0.sortDate < $1.sortDate
            }
            if $0.lastUpdatedAt != $1.lastUpdatedAt {
                return $0.lastUpdatedAt < $1.lastUpdatedAt
            }
            return $0.id < $1.id
        }
    }

    private func mergeTimelineItem(
        primary: AssistantTimelineItem,
        cached: AssistantTimelineItem
    ) -> AssistantTimelineItem {
        guard primary.kind == .activity, cached.kind == .activity,
              var activity = primary.activity,
              let cachedActivity = cached.activity else {
            return primary.source == .codexSession ? primary : cached
        }

        if cachedActivity.updatedAt > activity.updatedAt {
            activity.status = cachedActivity.status
            activity.updatedAt = cachedActivity.updatedAt
            if let rawDetails = cachedActivity.rawDetails?.nonEmpty {
                activity.rawDetails = rawDetails
            }
            if let summary = cachedActivity.friendlySummary.nonEmpty {
                activity.friendlySummary = summary
            }
        }

        return .activity(activity)
    }

    private func appendTimelineMessage(
        _ item: AssistantTimelineItem,
        to items: inout [AssistantTimelineItem]
    ) {
        if let existingIndex = items.firstIndex(where: { $0.id == item.id }) {
            items[existingIndex] = item
            return
        }

        if let duplicateIndex = items.firstIndex(where: { timelineItemsShouldDeduplicate($0, item) }) {
            items[duplicateIndex] = mergedTimelineMessage(existing: items[duplicateIndex], incoming: item)
            return
        }

        items.append(item)
    }

    private func mergedTimelineMessage(
        existing: AssistantTimelineItem,
        incoming: AssistantTimelineItem
    ) -> AssistantTimelineItem {
        var merged = existing

        if merged.turnID?.nonEmpty == nil {
            merged.turnID = incoming.turnID?.nonEmpty
        }

        if (merged.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
           let incomingText = incoming.text?.trimmingCharacters(in: .whitespacesAndNewlines),
           !incomingText.isEmpty {
            merged.text = incomingText
        }

        let mergedImages = mergeImageData(existing.imageAttachments, incoming.imageAttachments)
        merged.imageAttachments = mergedImages.isEmpty ? nil : mergedImages
        return merged
    }

    private func mergeImageData(_ lhs: [Data]?, _ rhs: [Data]?) -> [Data] {
        let combined = (lhs ?? []) + (rhs ?? [])
        guard !combined.isEmpty else { return [] }

        var merged: [Data] = []
        var seen = Set<String>()
        for imageData in combined {
            let key = MemoryIdentifier.stableHexDigest(data: imageData)
            guard seen.insert(key).inserted else { continue }
            merged.append(imageData)
        }
        return merged
    }

    private func latestAssistantTimelineText(in items: [AssistantTimelineItem]) -> String? {
        for item in items.reversed() {
            switch item.kind {
            case .assistantProgress, .assistantFinal:
                if let text = item.text?.assistantNonEmpty {
                    return text
                }
            default:
                continue
            }
        }
        return nil
    }

    private func upsertTimelineActivity(
        _ activity: AssistantActivityItem,
        items: inout [AssistantTimelineItem],
        activityIndexByID: inout [String: Int]
    ) {
        let item = AssistantTimelineItem.activity(activity)
        if let existingIndex = activityIndexByID[activity.id] {
            items[existingIndex] = item
        } else if let existingIndex = items.firstIndex(where: { $0.id == activity.id }) {
            items[existingIndex] = item
            activityIndexByID[activity.id] = existingIndex
        } else {
            activityIndexByID[activity.id] = items.count
            items.append(item)
        }
    }

    private func updateTimelineActivityOutput(
        callID: String,
        kind: AssistantActivityKind,
        title: String,
        friendlySummary: String,
        rawDetails: String?,
        status: AssistantActivityStatus,
        sessionID: String,
        timestamp: Date,
        items: inout [AssistantTimelineItem],
        activityIndexByID: inout [String: Int]
    ) {
        if let existingIndex = activityIndexByID[callID],
           var activity = items[existingIndex].activity {
            activity.status = status
            activity.updatedAt = timestamp
            activity.rawDetails = combineActivityDetails(activity.rawDetails, rawDetails)
            activity.friendlySummary = friendlySummary.nonEmpty ?? activity.friendlySummary
            items[existingIndex] = .activity(activity)
            return
        }

        let activity = AssistantActivityItem(
            id: callID,
            sessionID: sessionID,
            turnID: nil,
            kind: kind,
            title: title,
            status: status,
            friendlySummary: friendlySummary,
            rawDetails: truncatedTimelineDetail(rawDetails),
            startedAt: timestamp,
            updatedAt: timestamp,
            source: .codexSession
        )
        upsertTimelineActivity(activity, items: &items, activityIndexByID: &activityIndexByID)
    }

    private func appendSavedActivityImagePreviewIfNeeded(
        callID: String,
        sessionCWD: String?,
        timestamp: Date,
        items: inout [AssistantTimelineItem],
        activityIndexByID: [String: Int]
    ) {
        guard let existingIndex = activityIndexByID[callID],
              let activity = items[existingIndex].activity else {
            return
        }

        let imageAttachments = assistantActivityImageAttachments(
            for: activity,
            sessionCWD: sessionCWD,
            maxCount: 3
        )
        guard !imageAttachments.isEmpty else { return }

        let imageItem = AssistantTimelineItem.system(
            id: "saved-activity-screenshot-\(callID)",
            sessionID: activity.sessionID,
            turnID: activity.turnID,
            text: "Screenshot captured during \(activity.title)",
            createdAt: timestamp,
            imageAttachments: imageAttachments,
            source: .codexSession
        )
        appendTimelineMessage(imageItem, to: &items)
    }

    private func timelineItemsShouldDeduplicate(
        _ lhs: AssistantTimelineItem,
        _ rhs: AssistantTimelineItem
    ) -> Bool {
        // Turn-based dedup: items from the same turn with compatible kinds
        // are always duplicates, regardless of timestamps or text variations.
        if let lhsTurnID = lhs.turnID?.nonEmpty,
           let rhsTurnID = rhs.turnID?.nonEmpty,
           lhsTurnID.caseInsensitiveCompare(rhsTurnID) == .orderedSame {
            switch (lhs.kind, rhs.kind) {
            case (.assistantProgress, .assistantProgress),
                 (.assistantFinal, .assistantFinal),
                 (.assistantProgress, .assistantFinal),
                 (.assistantFinal, .assistantProgress):
                return true
            case (.userMessage, .userMessage):
                return true
            case (.plan, .plan):
                return true
            default:
                break
            }
        }

        switch (lhs.kind, rhs.kind) {
        case (.activity, .activity):
            return lhs.activity?.id == rhs.activity?.id

        case (.userMessage, .userMessage),
             (.system, .system):
            return normalizedDeduplicationText(lhs.text ?? "") == normalizedDeduplicationText(rhs.text ?? "")
                && abs(lhs.createdAt.timeIntervalSince(rhs.createdAt)) < 1

        case (.assistantProgress, .assistantProgress),
             (.assistantFinal, .assistantFinal),
             (.assistantProgress, .assistantFinal),
             (.assistantFinal, .assistantProgress):
            return normalizedDeduplicationText(lhs.text ?? "") == normalizedDeduplicationText(rhs.text ?? "")
                && abs(lhs.createdAt.timeIntervalSince(rhs.createdAt)) < 120

        case (.permission, .permission):
            return lhs.permissionRequest?.toolTitle == rhs.permissionRequest?.toolTitle
                && abs(lhs.createdAt.timeIntervalSince(rhs.createdAt)) < 1

        case (.plan, .plan):
            return normalizedDeduplicationText(lhs.planText ?? "") == normalizedDeduplicationText(rhs.planText ?? "")

        default:
            return false
        }
    }

    private func savedFunctionCallActivity(
        payload: [String: Any],
        sessionID: String,
        timestamp: Date
    ) -> AssistantActivityItem? {
        let name = firstNonEmptyString(
            stringValue(payload["name"]),
            stringValue(payload["tool"])
        ) ?? "tool"
        let callID = firstNonEmptyString(
            stringValue(payload["call_id"]),
            stringValue(payload["callId"]),
            stringValue(payload["id"])
        ) ?? UUID().uuidString
        let arguments = stringValue(payload["arguments"])
        let kind = savedActivityKind(forToolName: name)
        let title = formattedToolTitle(from: name) ?? "Tool"
        let details = savedActivityDetails(kind: kind, toolName: name, arguments: arguments, input: nil)

        return AssistantActivityItem(
            id: callID,
            sessionID: sessionID,
            turnID: nil,
            kind: kind,
            title: title,
            status: savedActivityStatus(from: stringValue(payload["status"]), default: .running),
            friendlySummary: savedActivitySummary(kind: kind, title: title),
            rawDetails: details,
            startedAt: timestamp,
            updatedAt: timestamp,
            source: .codexSession
        )
    }

    private func savedCustomToolActivity(
        payload: [String: Any],
        sessionID: String,
        timestamp: Date
    ) -> AssistantActivityItem? {
        let name = firstNonEmptyString(
            stringValue(payload["name"]),
            stringValue(payload["tool"])
        ) ?? "custom_tool"
        let callID = firstNonEmptyString(
            stringValue(payload["call_id"]),
            stringValue(payload["callId"]),
            stringValue(payload["id"])
        ) ?? UUID().uuidString
        let kind = savedActivityKind(forToolName: name)
        let title = formattedToolTitle(from: name) ?? "Custom Tool"
        let input = stringValue(payload["input"])
        let details = savedActivityDetails(kind: kind, toolName: name, arguments: nil, input: input)

        return AssistantActivityItem(
            id: callID,
            sessionID: sessionID,
            turnID: nil,
            kind: kind,
            title: title,
            status: savedActivityStatus(from: stringValue(payload["status"]), default: .completed),
            friendlySummary: savedActivitySummary(kind: kind, title: title),
            rawDetails: details,
            startedAt: timestamp,
            updatedAt: timestamp,
            source: .codexSession
        )
    }

    private func savedActivityKind(forToolName name: String) -> AssistantActivityKind {
        let lowercased = name.lowercased()
        if lowercased == "exec_command" {
            return .commandExecution
        }
        if lowercased == "apply_patch" {
            return .fileChange
        }
        if lowercased.hasPrefix("mcp__") {
            return .mcpToolCall
        }
        return .dynamicToolCall
    }

    private func savedActivityStatus(
        from rawStatus: String?,
        default fallback: AssistantActivityStatus
    ) -> AssistantActivityStatus {
        guard let rawStatus = rawStatus?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return fallback
        }

        switch rawStatus {
        case "pending", "queued":
            return .pending
        case "running", "inprogress", "in_progress", "started", "working":
            return .running
        case "waiting":
            return .waiting
        case "interrupted", "cancelled", "canceled":
            return .interrupted
        case "failed", "errored", "error":
            return .failed
        case "completed", "complete", "succeeded", "success":
            return .completed
        default:
            return fallback
        }
    }

    private func savedActivitySummary(
        kind: AssistantActivityKind,
        title: String
    ) -> String {
        switch kind {
        case .commandExecution:
            return "Ran a terminal command."
        case .fileChange:
            return "Edited files in the workspace."
        case .webSearch:
            return "Searched the web."
        case .browserAutomation:
            return "Used the browser."
        case .mcpToolCall:
            return "Used an MCP tool."
        case .dynamicToolCall:
            switch title {
            case "Browser Use":
                return "Used the browser."
            case "App Action":
                return "Used a Mac app."
            case "Image Generation":
                return "Generated an image."
            default:
                return "Used \(title)."
            }
        case .subagent:
            return "Worked with a subagent."
        case .reasoning:
            return "Reasoned about the task."
        case .other:
            return "Ran a tool."
        }
    }

    private func savedActivityDetails(
        kind: AssistantActivityKind,
        toolName: String,
        arguments: String?,
        input: String?
    ) -> String? {
        switch kind {
        case .commandExecution:
            return truncatedTimelineDetail(extractCommand(fromJSONString: arguments) ?? arguments)
        case .fileChange:
            return truncatedTimelineDetail(input ?? arguments)
        default:
            return truncatedTimelineDetail(input ?? arguments ?? toolName)
        }
    }

    private func decodeSavedOutput(_ rawValue: Any?) -> String? {
        if let text = stringValue(rawValue)?.nonEmpty {
            if let outputPayload = decodedJSONObject(from: text),
               let output = firstNonEmptyString(
                stringValue(outputPayload["output"]),
                extractString(outputPayload["metadata"])
               ) {
                return truncatedTimelineDetail(output)
            }
            return truncatedTimelineDetail(text)
        }

        return truncatedTimelineDetail(extractString(rawValue))
    }

    private func extractCommand(fromJSONString rawJSON: String?) -> String? {
        guard let rawJSON = rawJSON?.nonEmpty,
              let json = decodedJSONObject(from: rawJSON) else {
            return nil
        }
        return firstNonEmptyString(
            stringValue(json["cmd"]),
            stringValue(json["command"])
        )
    }

    private func formattedToolTitle(from rawName: String?) -> String? {
        guard let rawName = rawName?.nonEmpty else { return nil }
        let lowercased = rawName.lowercased()
        if lowercased == "exec_command" {
            return "Command"
        }
        if lowercased == "apply_patch" {
            return "File Changes"
        }
        if lowercased == "generate_image" {
            return "Image Generation"
        }
        if rawName.hasPrefix("mcp__") {
            let components = rawName.split(separator: "_")
            if components.count >= 4 {
                let server = components[2]
                let tool = components.dropFirst(3).joined(separator: "_")
                let cleanedTool = tool.replacingOccurrences(of: "_", with: " ")
                return "\(server.uppercased()): \(cleanedTool.capitalized)"
            }
            return "MCP Tool"
        }
        return rawName
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "([A-Z])", with: " $1", options: .regularExpression)
            .capitalized
    }

    private func combineActivityDetails(_ lhs: String?, _ rhs: String?) -> String? {
        let left = lhs?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let right = rhs?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        switch (left.isEmpty, right.isEmpty) {
        case (true, true):
            return nil
        case (false, true):
            return truncatedTimelineDetail(left)
        case (true, false):
            return truncatedTimelineDetail(right)
        case (false, false):
            if left == right {
                return truncatedTimelineDetail(left)
            }
            return truncatedTimelineDetail("\(left)\n\n\(right)")
        }
    }

    private func truncatedTimelineDetail(_ value: String?, limit: Int = 4_000) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }

        if value.count <= limit {
            return value
        }
        return String(value.prefix(limit - 1)) + "…"
    }

    private func decodedJSONObject(from rawJSONString: String) -> [String: Any]? {
        guard let data = rawJSONString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private func decodedJSONValue(from rawJSONString: String) -> Any? {
        guard let data = rawJSONString.data(using: .utf8) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private func parsePrimaryMetadata(from contents: String, fileURL: URL) -> SessionMetadata? {
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            guard let json = jsonObject(from: rawLine),
                  stringValue(json["type"]) == "session_meta",
                  let payload = dictionaryValue(json["payload"]) else {
                continue
            }

            let lineTimestamp = parseDate(stringValue(json["timestamp"]))
            let createdAt = parseDate(stringValue(payload["timestamp"])) ?? lineTimestamp
            let sessionID = firstNonEmptyString(
                stringValue(payload["id"]),
                sessionIDFromFilename(fileURL)
            ) ?? sessionIDFromFilename(fileURL)

            return SessionMetadata(
                id: sessionID,
                source: sessionSource(from: payload["source"], originator: firstNonEmptyString(stringValue(payload["originator"]))),
                parentThreadID: parentThreadID(from: payload["source"]),
                cwd: firstNonEmptyString(stringValue(payload["cwd"])),
                createdAt: createdAt,
                originator: firstNonEmptyString(stringValue(payload["originator"]))
            )
        }
        return nil
    }

    private func sessionSource(from rawValue: Any?, originator: String?) -> AssistantSessionSource {
        if originator?.caseInsensitiveCompare("Open Assist") == .orderedSame {
            return .appServer
        }

        guard let rawSource = normalizedSourceValue(rawValue)?.lowercased() else {
            return .other
        }

        switch rawSource {
        case "cli":
            return .cli
        case "vscode", "vs_code", "visual_studio_code":
            return .vscode
        case "exec", "appserver", "app_server", "app-server":
            return .appServer
        default:
            return .other
        }
    }

    private func parentThreadID(from rawValue: Any?) -> String? {
        guard let source = dictionaryValue(rawValue),
              let subagent = dictionaryValue(source["subagent"]),
              let threadSpawn = dictionaryValue(subagent["thread_spawn"]) else {
            return nil
        }

        return firstNonEmptyString(
            stringValue(threadSpawn["parent_thread_id"]),
            stringValue(threadSpawn["parentThreadId"])
        )
    }

    private func normalizedSourceValue(_ rawValue: Any?) -> String? {
        if let rawValue = rawValue as? String {
            return rawValue.nonEmpty
        }

        guard let dictionary = dictionaryValue(rawValue) else {
            return nil
        }

        return firstNonEmptyString(
            stringValue(dictionary["type"]),
            stringValue(dictionary["kind"]),
            stringValue(dictionary["name"])
        )
    }

    private func compareSessions(
        _ lhs: AssistantSessionSummary,
        _ rhs: AssistantSessionSummary,
        preferredThreadID: String?,
        preferredCWD: String?
    ) -> Bool {
        let lhsThreadMatch = lhs.id == preferredThreadID
        let rhsThreadMatch = rhs.id == preferredThreadID
        if lhsThreadMatch != rhsThreadMatch {
            return lhsThreadMatch
        }

        let lhsCWDMatch = normalizedCWD(lhs.cwd) == normalizedCWD(preferredCWD)
        let rhsCWDMatch = normalizedCWD(rhs.cwd) == normalizedCWD(preferredCWD)
        if lhsCWDMatch != rhsCWDMatch {
            return lhsCWDMatch
        }

        let lhsDate = lhs.updatedAt ?? lhs.createdAt ?? .distantPast
        let rhsDate = rhs.updatedAt ?? rhs.createdAt ?? .distantPast
        if lhsDate != rhsDate {
            return lhsDate > rhsDate
        }

        if lhs.title != rhs.title {
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }

        return lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
    }

    private func inferredStatus(
        latestUserMessage: String?,
        latestAssistantMessage: String?
    ) -> AssistantSessionStatus {
        if latestAssistantMessage?.nonEmpty != nil {
            return .idle
        }
        if latestUserMessage?.nonEmpty != nil {
            return .active
        }
        return .unknown
    }

    private func preferredSessionTitle(
        latestUserMessage: String?,
        latestAssistantMessage: String?,
        cwd: String?
    ) -> String? {
        if let latestUserMessage,
           latestUserMessage.count >= 6 {
            return latestUserMessage
        }
        if let latestAssistantMessage {
            return latestAssistantMessage
        }
        guard let cwd = cwd?.nonEmpty else {
            return nil
        }
        let standardized = URL(fileURLWithPath: cwd).standardizedFileURL.path
        let lastComponent = URL(fileURLWithPath: standardized).lastPathComponent.nonEmpty
        return lastComponent ?? standardized
    }

    private func loadSessionIndexRecords() -> [String: SessionIndexRecord] {
        guard let contents = try? String(contentsOf: sessionIndexURL, encoding: .utf8),
              !contents.isEmpty else {
            return [:]
        }

        var records: [String: SessionIndexRecord] = [:]
        for json in sessionIndexEntries(from: contents) {
            guard let record = sessionIndexRecord(from: json) else {
                continue
            }
            records[record.id.lowercased()] = record
        }
        return records
    }

    private func sessionIndexEntries(from contents: String) -> [[String: Any]] {
        guard !contents.isEmpty else { return [] }

        var entries: [[String: Any]] = []
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let rawText = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawText.isEmpty else { continue }

            if let json = jsonObject(from: Substring(rawText)) {
                entries.append(json)
                continue
            }

            let repaired = rawText.replacingOccurrences(
                of: #"(?<=\})\s*(?=\{)"#,
                with: "\n",
                options: .regularExpression
            )
            for candidate in repaired.split(whereSeparator: \.isNewline) {
                if let json = jsonObject(from: candidate) {
                    entries.append(json)
                }
            }
        }

        return entries
    }

    private func sessionIndexRecord(from json: [String: Any]) -> SessionIndexRecord? {
        guard let sessionID = stringValue(json["id"])?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return nil
        }

        return SessionIndexRecord(
            id: sessionID,
            threadName: firstNonEmptyString(
                stringValue(json["thread_name"]),
                stringValue(json["threadName"]),
                stringValue(json["title"])
            ),
            updatedAtRawValue: firstNonEmptyString(
                stringValue(json["updated_at"]),
                stringValue(json["updatedAt"])
            ),
            isArchived: boolValue(json["archived"]) ?? boolValue(json["is_archived"]) ?? false,
            archivedAt: parseDate(
                firstNonEmptyString(
                    stringValue(json["archived_at"]),
                    stringValue(json["archivedAt"])
                )
            ),
            archiveExpiresAt: parseDate(
                firstNonEmptyString(
                    stringValue(json["archive_expires_at"]),
                    stringValue(json["archiveExpiresAt"])
                )
            ),
            archiveUsesDefaultRetention: boolValue(json["archive_uses_default_retention"])
                ?? boolValue(json["archiveUsesDefaultRetention"])
        )
    }

    private func loadOrderedSessionIndexEntries() -> [[String: Any]] {
        guard let contents = try? String(contentsOf: sessionIndexURL, encoding: .utf8),
              !contents.isEmpty else {
            return []
        }
        return sessionIndexEntries(from: contents)
    }

    private func writeSessionIndexEntries(_ entries: [[String: Any]]) throws {
        if entries.isEmpty {
            if fileManager.fileExists(atPath: sessionIndexURL.path) {
                try fileManager.removeItem(at: sessionIndexURL)
            }
            return
        }

        let codexDirectory = sessionIndexURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: codexDirectory.path) {
            try fileManager.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        }

        let lines = try entries.map { entry in
            let data = try JSONSerialization.data(withJSONObject: entry, options: [])
            guard let line = String(data: data, encoding: .utf8) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return line
        }
        let contents = lines.joined(separator: "\n") + "\n"
        try contents.write(to: sessionIndexURL, atomically: true, encoding: .utf8)
    }

    private func upsertSessionIndexRecord(
        for sessionID: String,
        mutate: (inout SessionIndexRecord) -> Void
    ) throws {
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionID.isEmpty else { return }

        let nowValue = Self.fractionalSecondsDateFormatter.string(from: Date())
        let entries = loadOrderedSessionIndexEntries()
        var updatedEntries: [[String: Any]] = []
        var didUpdateExisting = false

        for entry in entries {
            guard let entrySessionID = stringValue(entry["id"])?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
                  entrySessionID.caseInsensitiveCompare(normalizedSessionID) == .orderedSame else {
                updatedEntries.append(entry)
                continue
            }

            if didUpdateExisting {
                continue
            }

            var record = sessionIndexRecord(from: entry) ?? SessionIndexRecord(
                id: entrySessionID,
                threadName: nil,
                updatedAtRawValue: nil,
                isArchived: false,
                archivedAt: nil,
                archiveExpiresAt: nil,
                archiveUsesDefaultRetention: nil
            )
            mutate(&record)
            record.updatedAtRawValue = nowValue
            if record.hasMeaningfulMetadata {
                updatedEntries.append(
                    record.serializedJSON(dateFormatter: { Self.fractionalSecondsDateFormatter.string(from: $0) })
                )
            }
            didUpdateExisting = true
        }

        if !didUpdateExisting {
            var record = SessionIndexRecord(
                id: normalizedSessionID,
                threadName: nil,
                updatedAtRawValue: nowValue,
                isArchived: false,
                archivedAt: nil,
                archiveExpiresAt: nil,
                archiveUsesDefaultRetention: nil
            )
            mutate(&record)
            if record.hasMeaningfulMetadata {
                updatedEntries.append(
                    record.serializedJSON(dateFormatter: { Self.fractionalSecondsDateFormatter.string(from: $0) })
                )
            }
        }

        try writeSessionIndexEntries(updatedEntries)
    }

    private func removeSessionIndexRecord(sessionID: String) throws {
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionID.isEmpty else { return }

        let entries = loadOrderedSessionIndexEntries()
        let filtered = entries.filter { entry in
            guard let entrySessionID = stringValue(entry["id"])?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
                return true
            }
            return entrySessionID.caseInsensitiveCompare(normalizedSessionID) != .orderedSame
        }

        guard filtered.count != entries.count else { return }
        try writeSessionIndexEntries(filtered)
    }

    private func boolValue(_ raw: Any?) -> Bool? {
        switch raw {
        case let value as Bool:
            return value
        case let value as NSNumber:
            return value.boolValue
        case let value as String:
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch normalized {
            case "true", "yes", "1":
                return true
            case "false", "no", "0":
                return false
            default:
                return nil
            }
        default:
            return nil
        }
    }

    private func applyingSessionIndexRecord(
        _ summary: AssistantSessionSummary,
        record: SessionIndexRecord?
    ) -> AssistantSessionSummary {
        guard let record else {
            return summary
        }

        var updatedSummary = summary
        if let normalizedThreadName = record.threadName?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            updatedSummary.title = normalizedThreadName
        }
        updatedSummary.isArchived = record.isArchived
        updatedSummary.archivedAt = record.archivedAt
        updatedSummary.archiveExpiresAt = record.archiveExpiresAt
        updatedSummary.archiveUsesDefaultRetention = record.archiveUsesDefaultRetention
        if let archivedAt = record.archivedAt {
            updatedSummary.updatedAt = maxDate(updatedSummary.updatedAt, archivedAt)
        }
        return updatedSummary
    }

    private func sessionStartedText(for source: AssistantSessionSource) -> String {
        switch source {
        case .openAssist:
            return "Started an OpenAssist thread."
        case .cli:
            return "Started a Codex CLI session."
        case .vscode:
            return "Started a VS Code Codex session."
        case .appServer:
            return "Started an Open Assist session."
        case .other:
            return "Started a Codex session."
        }
    }

    private func deduplicateTranscriptCandidates(_ candidates: [TranscriptCandidate]) -> [TranscriptCandidate] {
        let sorted = candidates.sorted { lhs, rhs in
            if lhs.lineNumber != rhs.lineNumber {
                return lhs.lineNumber < rhs.lineNumber
            }
            return lhs.createdAt < rhs.createdAt
        }

        var deduped: [TranscriptCandidate] = []
        for candidate in sorted {
            if let previous = deduped.last,
               previous.role == candidate.role,
               normalizedDeduplicationText(previous.text) == normalizedDeduplicationText(candidate.text),
               abs(previous.createdAt.timeIntervalSince(candidate.createdAt)) < 1 {
                continue
            }
            deduped.append(candidate)
        }
        return deduped
    }

    private func normalizedDeduplicationText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
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

        // Server-echoed system context that carries no user-useful info.
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

    private func cleanedAssistantMessage(_ rawValue: String?) -> String? {
        guard var text = normalizeTranscriptMessage(rawValue) else {
            return nil
        }

        if text.hasPrefix("<proposed_plan>"),
           text.hasSuffix("</proposed_plan>") {
            text = text
                .replacingOccurrences(of: "<proposed_plan>", with: "")
                .replacingOccurrences(of: "</proposed_plan>", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return normalizeTranscriptMessage(text)
    }

    private func extractSuffix(after marker: String, in value: String) -> String? {
        guard let range = value.range(of: marker, options: [.caseInsensitive, .backwards]) else {
            return nil
        }
        return value[range.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
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
            // Drop injected context fragments that should not appear in the UI
            if normalized.hasPrefix("# Session Memory") { continue }
            uniqueFragments.append(normalized)
        }

        return normalizeTranscriptMessage(uniqueFragments.joined(separator: "\n\n"))
    }

    private func extractImageAttachments(from rawValue: Any?) -> [Data] {
        var attachments: [Data] = []
        var seen = Set<String>()
        collectImageAttachments(from: rawValue, into: &attachments, seen: &seen)
        return attachments
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
            if let output = stringValue(dictionary["output"]) {
                fragments.append(output)
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

    private func collectImageAttachments(
        from rawValue: Any?,
        into attachments: inout [Data],
        seen: inout Set<String>
    ) {
        switch rawValue {
        case let string as String:
            if let imageData = decodeImageDataURL(string) {
                let key = MemoryIdentifier.stableHexDigest(data: imageData)
                guard seen.insert(key).inserted else { return }
                attachments.append(imageData)
                return
            }
            if let jsonValue = decodedJSONValue(from: string) {
                collectImageAttachments(from: jsonValue, into: &attachments, seen: &seen)
            }

        case let array as [Any]:
            for item in array {
                collectImageAttachments(from: item, into: &attachments, seen: &seen)
            }

        case let dictionary as [String: Any]:
            if let imageURL = stringValue(dictionary["image_url"]) {
                collectImageAttachments(from: imageURL, into: &attachments, seen: &seen)
            }
            if let imageURL = dictionaryValue(dictionary["image_url"]),
               let url = stringValue(imageURL["url"]) {
                collectImageAttachments(from: url, into: &attachments, seen: &seen)
            }
            if let url = stringValue(dictionary["url"]) {
                collectImageAttachments(from: url, into: &attachments, seen: &seen)
            }
            if let images = dictionary["images"] {
                collectImageAttachments(from: images, into: &attachments, seen: &seen)
            }
            if let content = dictionary["content"] {
                collectImageAttachments(from: content, into: &attachments, seen: &seen)
            }

        default:
            break
        }
    }

    private func decodeImageDataURL(_ rawValue: String) -> Data? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:"),
              let commaIndex = trimmed.firstIndex(of: ",") else {
            return nil
        }

        let metadata = String(trimmed[..<commaIndex])
        let payload = String(trimmed[trimmed.index(after: commaIndex)...])
        guard metadata.lowercased().hasPrefix("data:image/"),
              metadata.contains(";base64") else {
            return nil
        }
        return Data(base64Encoded: payload)
    }

    private func parseDate(_ raw: String?) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }

        if let value = Self.fractionalSecondsDateFormatter.date(from: raw) {
            return value
        }

        return Self.standardDateFormatter.date(from: raw)
    }

    private func truncate(_ value: String?, limit: Int) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }

        if value.count <= limit {
            return value
        }

        return String(value.prefix(limit - 1)) + "..."
    }

    private func cleanSummaryText(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        return sanitizeAttachmentPlaceholders(in: value)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
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

    private func jsonObject(from rawLine: Substring) -> [String: Any]? {
        guard let data = String(rawLine).data(using: .utf8),
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

    private func extractString(_ rawValue: Any?) -> String? {
        switch rawValue {
        case let value as String:
            return value
        case let dictionary as [String: Any]:
            return firstNonEmptyString(
                stringValue(dictionary["text"]),
                stringValue(dictionary["message"]),
                stringValue(dictionary["output"]),
                stringValue(dictionary["reason"])
            )
        default:
            return nil
        }
    }

    private func firstNonEmptyString(_ values: String?...) -> String? {
        for value in values {
            if let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func sessionInteractionMode(
        collaborationMode: [String: Any]?,
        approvalPolicy: String?,
        sandboxPolicy: [String: Any]?
    ) -> AssistantInteractionMode? {
        let collaborationModeKind = firstNonEmptyString(
            stringValue(collaborationMode?["mode"])
        )?.lowercased()
        if collaborationModeKind == "plan" {
            return .plan
        }

        let normalizedApprovalPolicy = approvalPolicy?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalizedApprovalPolicy == "untrusted" {
            return .agentic
        }
        if normalizedApprovalPolicy == "on-request" || normalizedApprovalPolicy == "never" {
            return .agentic
        }

        let sandboxType = firstNonEmptyString(
            stringValue(sandboxPolicy?["type"])
        )?.lowercased()
        if sandboxType == "read-only" || sandboxType == "readonly" {
            return collaborationModeKind == "default" ? .agentic : nil
        }
        if sandboxType == "danger-full-access" || sandboxType == "dangerfullaccess" {
            return .agentic
        }

        return nil
    }

    private func jsonStringLine(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let line = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return line
    }

    private func maxDate(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            return max(lhs, rhs)
        case let (lhs?, nil):
            return lhs
        case let (nil, rhs?):
            return rhs
        case (nil, nil):
            return nil
        }
    }

    private func normalizedCWD(_ rawValue: String?) -> String? {
        guard let rawValue = rawValue?.nonEmpty else {
            return nil
        }
        return URL(fileURLWithPath: rawValue).standardizedFileURL.path
    }

    private func isRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]) else {
            return false
        }
        return values.isRegularFile == true
    }

    private func sessionIDFromFilename(_ fileURL: URL) -> String {
        let name = fileURL.deletingPathExtension().lastPathComponent
        if let range = name.range(
            of: #"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$"#,
            options: .regularExpression
        ) {
            return String(name[range])
        }
        return name
    }
}

private enum QuickSessionSummaryResult {
    case summary(AssistantSessionSummary)
    case filteredOut
    case needsFullParse
}

private struct SessionFileRecord {
    let url: URL
    let modificationDate: Date?
    let fileSize: Int
}

private struct SessionMetadata {
    let id: String
    let source: AssistantSessionSource
    let parentThreadID: String?
    let cwd: String?
    let createdAt: Date?
    let originator: String?

    func matchesOriginator(_ expectedOriginator: String) -> Bool {
        originator?.caseInsensitiveCompare(expectedOriginator) == .orderedSame
    }
}

private struct SessionTextSnapshot {
    let text: String
    let date: Date?
}

private struct SessionSummaryAccumulator {
    var updatedAt: Date?
    var latestModel: String?
    var latestInteractionMode: AssistantInteractionMode?
    var latestReasoningEffort: AssistantReasoningEffort?
    var latestServiceTier: String?
    var latestUser: SessionTextSnapshot?
    var latestAssistant: SessionTextSnapshot?
    var fallbackUser: SessionTextSnapshot?
    var fallbackAssistant: SessionTextSnapshot?
    var explicitStatus: AssistantSessionStatus?

    var hasRelevantTailContent: Bool {
        latestModel != nil
            || latestInteractionMode != nil
            || latestReasoningEffort != nil
            || latestServiceTier != nil
            || latestUser != nil
            || latestAssistant != nil
            || fallbackUser != nil
            || fallbackAssistant != nil
            || explicitStatus != nil
    }
}

private struct TranscriptCandidate {
    let lineNumber: Int
    let role: AssistantTranscriptRole
    let text: String
    let createdAt: Date
    let emphasis: Bool
}

private struct SessionFileSignature: Equatable {
    let modificationDate: Date?
    let fileSize: Int
}

private struct SessionQuickLookCacheEntry {
    let signature: SessionFileSignature
    var metadata: SessionMetadata?
    var metadataLoaded: Bool
    var summary: AssistantSessionSummary?
}

private enum SessionMetadataLookup {
    case hit(SessionMetadata?)
    case miss
}

private final class SessionQuickLookCache {
    private let lock = NSLock()
    private var entriesByPath: [String: SessionQuickLookCacheEntry] = [:]

    func summary(for file: SessionFileRecord) -> AssistantSessionSummary? {
        lock.lock()
        defer { lock.unlock() }

        guard let entry = entriesByPath[file.url.path],
              entry.signature == signature(for: file) else {
            return nil
        }
        return entry.summary
    }

    func metadataLookup(for file: SessionFileRecord) -> SessionMetadataLookup {
        lock.lock()
        defer { lock.unlock() }

        guard let entry = entriesByPath[file.url.path],
              entry.signature == signature(for: file),
              entry.metadataLoaded else {
            return .miss
        }
        return .hit(entry.metadata)
    }

    func store(metadata: SessionMetadata?, for file: SessionFileRecord) {
        lock.lock()
        defer { lock.unlock() }

        let key = file.url.path
        var entry = entriesByPath[key]
        let signature = signature(for: file)
        if entry?.signature != signature {
            entry = SessionQuickLookCacheEntry(
                signature: signature,
                metadata: metadata,
                metadataLoaded: true,
                summary: nil
            )
        } else {
            entry?.metadata = metadata
            entry?.metadataLoaded = true
        }
        entriesByPath[key] = entry
    }

    func store(summary: AssistantSessionSummary, metadata: SessionMetadata?, for file: SessionFileRecord) {
        lock.lock()
        defer { lock.unlock() }

        let key = file.url.path
        var entry = entriesByPath[key]
        let signature = signature(for: file)
        if entry?.signature != signature {
            entry = SessionQuickLookCacheEntry(
                signature: signature,
                metadata: metadata,
                metadataLoaded: true,
                summary: summary
            )
        } else {
            entry?.summary = summary
            if metadata != nil || entry?.metadataLoaded == false {
                entry?.metadata = metadata
                entry?.metadataLoaded = true
            }
        }
        entriesByPath[key] = entry
    }

    private func signature(for file: SessionFileRecord) -> SessionFileSignature {
        SessionFileSignature(
            modificationDate: file.modificationDate,
            fileSize: file.fileSize
        )
    }
}
