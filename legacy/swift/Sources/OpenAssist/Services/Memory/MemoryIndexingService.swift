import Foundation
import OSLog

struct MemoryIndexingReport: Sendable {
    var discoveredSources = 0
    var indexedFiles = 0
    var skippedFiles = 0
    var indexedEvents = 0
    var indexedCards = 0
    var indexedLessons = 0
    var indexedRewriteSuggestions = 0
    var failures: [String] = []

    var hasFailures: Bool {
        !failures.isEmpty
    }
}

actor MemoryIndexingService {
    static let shared = MemoryIndexingService()
    typealias ProgressHandler = @Sendable (_ report: MemoryIndexingReport, _ currentSource: MemoryDiscoveredSource?, _ currentFilePath: String?) async -> Void

    private static let aiNoIndexedOutputMarker = "__ai_no_indexed_output__"

    private let fileManager: FileManager
    private let adapterRegistry: MemorySourceAdapterRegistry
    private let rewriteProvider: MemoryRewriteExtractionProviding
    private let maxFilesPerSource: Int
    private let maxEventsPerFile: Int
    private let apiThrottleDelay: TimeInterval
    private let logger = Logger(subsystem: "com.developingadventures.OpenAssist", category: "MemoryIndexing")

    init(
        fileManager: FileManager = .default,
        adapterRegistry: MemorySourceAdapterRegistry = MemorySourceAdapterRegistry(),
        rewriteProvider: MemoryRewriteExtractionProviding = StubMemoryRewriteExtractionProvider.shared,
        maxFilesPerSource: Int = 350,
        maxEventsPerFile: Int = 80,
        apiThrottleDelay: TimeInterval = 1.0
    ) {
        self.fileManager = fileManager
        self.adapterRegistry = adapterRegistry
        self.rewriteProvider = rewriteProvider
        self.maxFilesPerSource = max(1, maxFilesPerSource)
        self.maxEventsPerFile = max(1, maxEventsPerFile)
        self.apiThrottleDelay = apiThrottleDelay
    }

    func rebuildIndex(
        from sources: [MemoryDiscoveredSource],
        store: MemorySQLiteStore,
        progress: ProgressHandler? = nil
    ) async -> MemoryIndexingReport {
        // Incremental rebuild: preserve stored file hashes and only re-index changed/new files.
        await indexSources(sources, store: store, progress: progress)
    }

    func rebuildFromScratch(
        from sources: [MemoryDiscoveredSource],
        store: MemorySQLiteStore,
        progress: ProgressHandler? = nil
    ) async -> MemoryIndexingReport {
        do {
            try store.clearAllIndexedData()
        } catch {
            return MemoryIndexingReport(
                failures: ["Failed to clear existing index data before rebuild: \(error.localizedDescription)"]
            )
        }
        return await indexSources(sources, store: store, progress: progress)
    }

    func indexSources(
        _ sources: [MemoryDiscoveredSource],
        store: MemorySQLiteStore,
        progress: ProgressHandler? = nil
    ) async -> MemoryIndexingReport {
        var report = MemoryIndexingReport()
        logger.info("Starting memory indexing for \(sources.count, privacy: .public) source(s).")
        if let progress {
            await progress(report, nil, nil)
        }

        if sources.isEmpty {
            logger.notice("Memory indexing received zero sources to process.")
        }

        for source in sources {
            if Task.isCancelled {
                break
            }
            report.discoveredSources += 1
            if let progress {
                await progress(report, source, nil)
            }
            await index(source: source, store: store, progress: progress, report: &report)
        }

        logger.info(
            "Memory indexing finished: indexedFiles=\(report.indexedFiles, privacy: .public) skippedFiles=\(report.skippedFiles, privacy: .public) indexedCards=\(report.indexedCards, privacy: .public) failures=\(report.failures.count, privacy: .public)"
        )
        return report
    }

    private func index(
        source: MemoryDiscoveredSource,
        store: MemorySQLiteStore,
        progress: ProgressHandler?,
        report: inout MemoryIndexingReport
    ) async {
        guard let adapter = adapterRegistry.adapter(for: source.provider) else {
            report.failures.append("No source adapter found for provider \(source.provider.rawValue)")
            if let progress {
                await progress(report, source, nil)
            }
            return
        }

        let sourceID = MemoryIdentifier.stableUUID(
            for: "source|\(source.provider.rawValue)|\(source.rootURL.path)"
        )
        let sourceRecord = MemorySource(
            id: sourceID,
            provider: source.provider,
            rootPath: source.rootURL.path,
            displayName: source.displayName,
            metadata: [
                "detail": source.detail,
                "source_id": source.id
            ]
        )

        do {
            try store.upsertSource(sourceRecord)
        } catch {
            report.failures.append("Failed to upsert source \(source.rootURL.path): \(error.localizedDescription)")
            if let progress {
                await progress(report, source, nil)
            }
            return
        }

        let candidateFiles = adapter.discoverFiles(
            in: source.rootURL,
            fileManager: fileManager,
            maxFiles: maxFilesPerSource
        )
        let aiBackedIndexingAvailable = await rewriteProvider.hasAIBackedIndexingAccess(for: source.provider)
        logger.debug(
            "Source \(source.provider.rawValue, privacy: .public) at \(source.rootURL.path, privacy: .public) has \(candidateFiles.count, privacy: .public) candidate file(s); aiBacked=\(aiBackedIndexingAvailable, privacy: .public)"
        )

        if candidateFiles.isEmpty {
            logger.notice(
                "Source \(source.provider.rawValue, privacy: .public) at \(source.rootURL.path, privacy: .public) had no parseable session JSONL files."
            )
        }

        for fileURL in candidateFiles {
            if Task.isCancelled {
                break
            }
            await index(
                fileURL: fileURL,
                source: source,
                sourceID: sourceID,
                adapter: adapter,
                aiBackedIndexingAvailable: aiBackedIndexingAvailable,
                store: store,
                progress: progress,
                report: &report
            )
        }

        if let progress {
            await progress(report, source, nil)
        }
    }

    private func index(
        fileURL: URL,
        source: MemoryDiscoveredSource,
        sourceID: UUID,
        adapter: any MemorySourceAdapter,
        aiBackedIndexingAvailable: Bool,
        store: MemorySQLiteStore,
        progress: ProgressHandler?,
        report: inout MemoryIndexingReport
    ) async {
        let relativePath = Self.relativePath(of: fileURL, to: source.rootURL)
        let fileID = MemoryIdentifier.stableUUID(
            for: "file|\(sourceID.uuidString)|\(relativePath)"
        )

        let sourceFileRecord = makeSourceFileRecord(
            id: fileID,
            sourceID: sourceID,
            fileURL: fileURL,
            relativePath: relativePath
        )

        do {
            let existing = try store.fetchSourceFile(
                sourceID: sourceID,
                relativePath: relativePath
            )
            if let existing {
                let hasNoOutputMarker = existing.parseError == Self.aiNoIndexedOutputMarker
                let unchanged = existing.fileHash == sourceFileRecord.fileHash
                    && (existing.parseError == nil || hasNoOutputMarker)

                if unchanged {
                    if !aiBackedIndexingAvailable {
                        report.skippedFiles += 1
                        if let progress {
                            await progress(report, source, fileURL.path)
                        }
                        return
                    }

                    let hasIndexedEvents = try store.hasIndexedEvents(forSourceFileID: fileID)
                    // Re-try files that previously produced no parse output so parser improvements
                    // can recover memories without requiring a destructive full reset.
                    if hasIndexedEvents {
                        report.skippedFiles += 1
                        if let progress {
                            await progress(report, source, fileURL.path)
                        }
                        return
                    }
                }

                if !unchanged || aiBackedIndexingAvailable {
                    try store.clearIndexedContent(forSourceFileID: fileID)
                }
            }

            try store.upsertSourceFile(sourceFileRecord)
        } catch {
            report.failures.append("Failed to stage source file \(fileURL.path): \(error.localizedDescription)")
            if let progress {
                await progress(report, source, fileURL.path)
            }
            return
        }

        do {
            let drafts = try adapter.parse(
                fileURL: fileURL,
                relativePath: relativePath,
                fileManager: fileManager
            )
            if drafts.isEmpty {
                if aiBackedIndexingAvailable {
                    var noOutputFile = sourceFileRecord
                    noOutputFile.parseError = Self.aiNoIndexedOutputMarker
                    noOutputFile.indexedAt = Date()
                    try store.upsertSourceFile(noOutputFile)
                }

                report.skippedFiles += 1
                if let progress {
                    await progress(report, source, fileURL.path)
                }
                return
            }

            report.indexedFiles += 1
            let limitedDrafts = Array(drafts.prefix(maxEventsPerFile))

            // AI mode controls memory persistence. Without AI-backed indexing access,
            // we still count parsed files but intentionally skip writing events/cards.
            if !aiBackedIndexingAvailable {
                if let progress {
                    await progress(report, source, fileURL.path)
                }
                return
            }

            var persistedIndexedOutput = false
            for (index, draft) in limitedDrafts.enumerated() {
                if Task.isCancelled {
                    break
                }

                let eventID = MemoryIdentifier.stableUUID(
                    for: "event|\(fileID.uuidString)|\(index)|\(draft.kind.rawValue)|\(draft.title)|\(draft.body)"
                )
                let event = MemoryEvent(
                    id: eventID,
                    sourceID: sourceID,
                    sourceFileID: fileID,
                    provider: source.provider,
                    kind: draft.kind,
                    title: draft.title,
                    body: draft.body,
                    timestamp: draft.timestamp,
                    nativeSummary: draft.nativeSummary,
                    keywords: draft.keywords,
                    isPlanContent: draft.isPlanContent,
                    metadata: draft.metadata,
                    rawPayload: draft.rawPayload
                )

                let summary = await rewriteProvider.summary(for: draft, provider: source.provider)
                let card = makeMemoryCard(
                    sourceID: sourceID,
                    sourceFileID: fileID,
                    eventID: eventID,
                    provider: source.provider,
                    draft: draft,
                    summary: summary
                )

                let lessonDraft = await rewriteProvider.lesson(
                    for: draft,
                    card: card,
                    provider: source.provider
                )
                let rewriteSuggestion = await rewriteProvider.rewriteSuggestion(
                    for: draft,
                    card: card,
                    provider: source.provider
                )

                // Persist core memory for every parsed draft; lesson/rewrite are optional enrichments.
                try store.upsertEvent(event)
                report.indexedEvents += 1
                try store.upsertCard(card)
                report.indexedCards += 1
                persistedIndexedOutput = true

                var lessonRewriteSuggestion: RewriteSuggestion?
                if let lessonDraft {
                    let lesson = makeMemoryLesson(
                        sourceID: sourceID,
                        sourceFileID: fileID,
                        eventID: eventID,
                        cardID: card.id,
                        provider: source.provider,
                        lessonDraft: lessonDraft
                    )
                    try store.upsertLesson(lesson)
                    try store.supersedeCompetingLessons(
                        with: lesson,
                        reason: "Superseded by a newer higher-confidence indexed lesson."
                    )
                    report.indexedLessons += 1

                    lessonRewriteSuggestion = makeRewriteSuggestion(
                        cardID: card.id,
                        provider: source.provider,
                        mistakePattern: lessonDraft.mistakePattern,
                        improvedPrompt: lessonDraft.improvedPrompt,
                        rationale: lessonDraft.rationale,
                        confidence: lessonDraft.validationConfidence
                    )
                    if let lessonRewriteSuggestion {
                        try store.insertRewriteSuggestion(lessonRewriteSuggestion)
                        report.indexedRewriteSuggestions += 1
                    }
                }

                if let rewriteSuggestion {
                    try store.insertRewriteSuggestion(rewriteSuggestion)
                    if lessonRewriteSuggestion?.id != rewriteSuggestion.id {
                        report.indexedRewriteSuggestions += 1
                    }
                }

                if apiThrottleDelay > 0 {
                    try await Task.sleep(nanoseconds: UInt64(apiThrottleDelay * 1_000_000_000))
                }
            }

            if aiBackedIndexingAvailable && !persistedIndexedOutput {
                var noOutputFile = sourceFileRecord
                noOutputFile.parseError = Self.aiNoIndexedOutputMarker
                noOutputFile.indexedAt = Date()
                try store.upsertSourceFile(noOutputFile)
            }

            if let progress {
                await progress(report, source, fileURL.path)
            }
        } catch {
            report.failures.append("Failed to index file \(fileURL.path): \(error.localizedDescription)")
            do {
                var erroredFile = sourceFileRecord
                erroredFile.parseError = error.localizedDescription
                erroredFile.indexedAt = Date()
                try store.upsertSourceFile(erroredFile)
            } catch {
                report.failures.append("Failed to save parse error for \(fileURL.path): \(error.localizedDescription)")
            }
            if let progress {
                await progress(report, source, fileURL.path)
            }
        }
    }

    private func makeSourceFileRecord(
        id: UUID,
        sourceID: UUID,
        fileURL: URL,
        relativePath: String
    ) -> MemorySourceFile {
        let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modifiedAt = values?.contentModificationDate ?? Date()
        let fileSize = Int64(values?.fileSize ?? 0)
        let fileHash: String
        if let data = fileManager.contents(atPath: fileURL.path) {
            fileHash = MemoryIdentifier.stableHexDigest(data: data)
        } else {
            fileHash = MemoryIdentifier.stableHexDigest(for: "\(fileURL.path)|\(modifiedAt.timeIntervalSince1970)|\(fileSize)")
        }

        return MemorySourceFile(
            id: id,
            sourceID: sourceID,
            absolutePath: fileURL.path,
            relativePath: relativePath,
            fileHash: fileHash,
            fileSizeBytes: fileSize,
            modifiedAt: modifiedAt,
            indexedAt: Date(),
            parseError: nil
        )
    }

    private func makeMemoryCard(
        sourceID: UUID,
        sourceFileID: UUID,
        eventID: UUID,
        provider: MemoryProviderKind,
        draft: MemoryEventDraft,
        summary: String?
    ) -> MemoryCard {
        let cardSummary = MemoryTextNormalizer.normalizedSummary(summary ?? draft.title)
        let detail = MemoryTextNormalizer.normalizedBody(draft.body)
        let score = baseScore(for: draft.kind, hasRewriteHint: draft.kind == .rewrite)
        let createdAt = draft.timestamp
        let cardID = MemoryIdentifier.stableUUID(
            for: "card|\(eventID.uuidString)|\(cardSummary)|\(detail)"
        )

        return MemoryCard(
            id: cardID,
            sourceID: sourceID,
            sourceFileID: sourceFileID,
            eventID: eventID,
            provider: provider,
            title: MemoryTextNormalizer.normalizedTitle(draft.title),
            summary: cardSummary,
            detail: detail,
            keywords: draft.keywords,
            score: score,
            createdAt: createdAt,
            updatedAt: createdAt,
            isPlanContent: draft.isPlanContent,
            metadata: draft.metadata
        )
    }

    private func makeMemoryLesson(
        sourceID: UUID,
        sourceFileID: UUID,
        eventID: UUID,
        cardID: UUID,
        provider: MemoryProviderKind,
        lessonDraft: MemoryLessonDraft
    ) -> MemoryLesson {
        let mistakePattern = MemoryTextNormalizer.normalizedBody(lessonDraft.mistakePattern)
        let improvedPrompt = MemoryTextNormalizer.normalizedBody(lessonDraft.improvedPrompt)
        let rationale = MemoryTextNormalizer.normalizedSummary(lessonDraft.rationale, limit: 400)
        let normalizedConfidence = min(1, max(0, lessonDraft.validationConfidence))
        let createdAt = Date()

        let lessonID = MemoryIdentifier.stableUUID(
            for: "lesson|\(cardID.uuidString)|\(mistakePattern)|\(improvedPrompt)"
        )

        return MemoryLesson(
            id: lessonID,
            sourceID: sourceID,
            sourceFileID: sourceFileID,
            eventID: eventID,
            cardID: cardID,
            provider: provider,
            mistakePattern: mistakePattern,
            improvedPrompt: improvedPrompt,
            rationale: rationale,
            validationConfidence: normalizedConfidence,
            sourceMetadata: lessonDraft.sourceMetadata,
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }

    private func makeRewriteSuggestion(
        cardID: UUID,
        provider: MemoryProviderKind,
        mistakePattern: String,
        improvedPrompt: String,
        rationale: String,
        confidence: Double
    ) -> RewriteSuggestion? {
        let original = MemoryTextNormalizer.collapsedWhitespace(mistakePattern)
        let suggested = MemoryTextNormalizer.collapsedWhitespace(improvedPrompt)
        guard !original.isEmpty, !suggested.isEmpty else { return nil }
        guard original.caseInsensitiveCompare(suggested) != .orderedSame else { return nil }

        return RewriteSuggestion(
            id: MemoryIdentifier.stableUUID(
                for: "\(cardID.uuidString)|rewrite|\(original)|\(suggested)"
            ),
            cardID: cardID,
            provider: provider,
            originalText: original,
            suggestedText: suggested,
            rationale: MemoryTextNormalizer.normalizedSummary(rationale, limit: 320),
            confidence: min(1.0, max(0.05, confidence)),
            createdAt: Date()
        )
    }

    private func baseScore(for kind: MemoryEventKind, hasRewriteHint: Bool) -> Double {
        let base: Double
        switch kind {
        case .rewrite:
            base = 1.0
        case .summary:
            base = 0.85
        case .conversation:
            base = 0.72
        case .note:
            base = 0.62
        case .fileEdit:
            base = 0.58
        case .command:
            base = 0.5
        case .plan:
            base = 0.24
        case .unknown:
            base = 0.4
        }
        return hasRewriteHint ? min(1.0, base + 0.08) : base
    }

    private static func relativePath(of fileURL: URL, to rootURL: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        if filePath == rootPath {
            return ""
        }
        if filePath.hasPrefix(rootPath + "/") {
            let suffix = String(filePath.dropFirst(rootPath.count))
            return suffix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return fileURL.lastPathComponent
    }
}
