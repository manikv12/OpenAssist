import Foundation
import OSLog

@MainActor
final class MemoryIndexingSettingsService {
    struct MaintenanceResult: Hashable {
        let didRun: Bool
        let message: String
    }

    struct MemoryAnalyticsOverview: Hashable {
        let repeatedMistakesAvoided: Int
        let invalidationRate: Double
        let fixSuccessRate: Double
        let totalTrackedAttempts: Int
    }

    struct MemoryAnalyticsBreakdownRow: Identifiable, Hashable {
        let id: String
        let providerID: String
        let providerName: String
        let projectName: String
        let totalAttempts: Int
        let fixedCount: Int
        let invalidatedCount: Int
        let successRate: Double
    }

    struct MemoryAnalyticsSnapshot: Hashable {
        let overview: MemoryAnalyticsOverview
        let rows: [MemoryAnalyticsBreakdownRow]
    }

    struct Provider: Identifiable, Hashable {
        let id: String
        let name: String
        let detail: String
        let sourceCount: Int
    }

    struct SourceFolder: Identifiable, Hashable {
        let id: String
        let name: String
        let path: String
        let providerID: String
    }

    struct ScanResult {
        let providers: [Provider]
        let sourceFolders: [SourceFolder]
        let indexQueued: Bool
        let queuedSourceCount: Int
    }

    static let shared = MemoryIndexingSettingsService()
    static let indexingDidProgressNotification = Notification.Name("OpenAssist.memoryIndexingDidProgress")
    static let indexingDidFinishNotification = Notification.Name("OpenAssist.memoryIndexingDidFinish")

    enum IndexingNotificationUserInfoKey {
        static let rebuild = "rebuild"
        static let cancelled = "cancelled"
        static let totalSources = "totalSources"
        static let discoveredSources = "discoveredSources"
        static let currentSourceDisplayName = "currentSourceDisplayName"
        static let currentFilePath = "currentFilePath"
        static let indexedFiles = "indexedFiles"
        static let skippedFiles = "skippedFiles"
        static let indexedEvents = "indexedEvents"
        static let indexedCards = "indexedCards"
        static let indexedLessons = "indexedLessons"
        static let indexedRewriteSuggestions = "indexedRewriteSuggestions"
        static let failureCount = "failureCount"
        static let firstFailure = "firstFailure"
    }

    private let discoveryService: MemoryProviderDiscoveryService
    private let indexingService: MemoryIndexingService
    private let storeFactory: @Sendable () throws -> MemorySQLiteStore
    private let logger = Logger(subsystem: "com.manikvashith.OpenAssist", category: "MemoryIndexing")
    private var activeIndexTask: Task<Void, Never>?
    private var activeIndexTaskGeneration = 0
    private var activeIndexingRebuild = false
    private var activeIndexingTotalSources = 0
    private var activeIndexingReport = MemoryIndexingReport()

    init(
        discoveryService: MemoryProviderDiscoveryService = .shared,
        indexingService: MemoryIndexingService = .shared,
        storeFactory: @escaping @Sendable () throws -> MemorySQLiteStore = { try MemorySQLiteStore() }
    ) {
        self.discoveryService = discoveryService
        self.indexingService = indexingService
        self.storeFactory = storeFactory
    }

    func detectedProviders(
        enabledProviderIDs: [String] = [],
        enabledSourceFolderIDs: [String] = []
    ) -> [Provider] {
        let discovery = discoveryService.discover(
            enabledProviders: enabledProviderIDs.isEmpty ? nil : Set(enabledProviderIDs),
            enabledSourceFolders: enabledSourceFolderIDs.isEmpty ? nil : Set(enabledSourceFolderIDs)
        )
        return discovery.providers.map(Self.makeProvider)
    }

    func detectedSourceFolders(
        enabledProviderIDs: [String] = [],
        enabledSourceFolderIDs: [String] = []
    ) -> [SourceFolder] {
        let discovery = discoveryService.discover(
            enabledProviders: enabledProviderIDs.isEmpty ? nil : Set(enabledProviderIDs),
            enabledSourceFolders: enabledSourceFolderIDs.isEmpty ? nil : Set(enabledSourceFolderIDs)
        )
        return discovery.sourceFolders.map(Self.makeSourceFolder)
    }

    func rescan(
        enabledProviderIDs: [String] = [],
        enabledSourceFolderIDs: [String] = [],
        runIndexing: Bool
    ) -> ScanResult {
        let discovery = discoveryService.discover()
        logger.info(
            "Rescan discovered \(discovery.providers.count, privacy: .public) source providers and \(discovery.sourceFolders.count, privacy: .public) source folders. runIndexing=\(runIndexing, privacy: .public)"
        )
        var indexQueued = false
        var queuedSourceCount = 0

        if runIndexing && FeatureFlags.aiMemoryEnabled {
            let enabledSources = enabledSourcesForIndexing(
                enabledProviderIDs: enabledProviderIDs,
                enabledSourceFolderIDs: enabledSourceFolderIDs
            )
            queuedSourceCount = enabledSources.count
            if !enabledSources.isEmpty {
                queueIndexing(sources: enabledSources, rebuild: false, clearBeforeIndexing: false)
                indexQueued = true
            } else {
                logger.notice("Rescan did not queue indexing because no enabled source folders matched current selection.")
            }
        } else if runIndexing {
            logger.notice("Rescan skipped indexing because AI memory feature flag is disabled.")
        } else {
            logger.notice("Rescan skipped indexing because AI memory assistant is paused.")
        }

        return ScanResult(
            providers: discovery.providers.map(Self.makeProvider),
            sourceFolders: discovery.sourceFolders.map(Self.makeSourceFolder),
            indexQueued: indexQueued,
            queuedSourceCount: queuedSourceCount
        )
    }

    func rebuildIndex(
        enabledProviderIDs: [String] = [],
        enabledSourceFolderIDs: [String] = []
    ) {
        guard FeatureFlags.aiMemoryEnabled else {
            postIndexingDidFinishNotification(
                rebuild: true,
                cancelled: false,
                totalSources: 0,
                report: MemoryIndexingReport()
            )
            return
        }
        let enabledSources = enabledSourcesForIndexing(
            enabledProviderIDs: enabledProviderIDs,
            enabledSourceFolderIDs: enabledSourceFolderIDs
        )
        guard !enabledSources.isEmpty else {
            postIndexingDidFinishNotification(
                rebuild: true,
                cancelled: false,
                totalSources: 0,
                report: MemoryIndexingReport()
            )
            return
        }
        queueIndexing(sources: enabledSources, rebuild: true, clearBeforeIndexing: false)
    }

    func rebuildIndexFromScratch(
        enabledProviderIDs: [String] = [],
        enabledSourceFolderIDs: [String] = []
    ) {
        guard FeatureFlags.aiMemoryEnabled else {
            postIndexingDidFinishNotification(
                rebuild: true,
                cancelled: false,
                totalSources: 0,
                report: MemoryIndexingReport()
            )
            return
        }
        let enabledSources = enabledSourcesForIndexing(
            enabledProviderIDs: enabledProviderIDs,
            enabledSourceFolderIDs: enabledSourceFolderIDs
        )
        guard !enabledSources.isEmpty else {
            postIndexingDidFinishNotification(
                rebuild: true,
                cancelled: false,
                totalSources: 0,
                report: MemoryIndexingReport()
            )
            return
        }
        queueIndexing(sources: enabledSources, rebuild: true, clearBeforeIndexing: true)
    }

    @discardableResult
    func cancelIndexing() -> Bool {
        guard activeIndexTask != nil else { return false }

        activeIndexTaskGeneration += 1
        activeIndexTask?.cancel()
        activeIndexTask = nil

        postIndexingDidFinishNotification(
            rebuild: activeIndexingRebuild,
            cancelled: true,
            totalSources: activeIndexingTotalSources,
            report: activeIndexingReport
        )
        logger.notice(
            "Indexing cancelled by user. indexedFiles=\(self.activeIndexingReport.indexedFiles, privacy: .public) skippedFiles=\(self.activeIndexingReport.skippedFiles, privacy: .public) indexedCards=\(self.activeIndexingReport.indexedCards, privacy: .public)"
        )

        activeIndexingReport = MemoryIndexingReport()
        activeIndexingTotalSources = 0
        activeIndexingRebuild = false
        return true
    }

    func clearMemories() {
        do {
            let store = try storeFactory()
            try store.clearIndexedMemories()
        } catch {
            // best effort cleanup
        }
    }

    func clearArchive() {
        do {
            let store = try storeFactory()
            try store.clearAllIndexedData()
        } catch {
            // best effort cleanup
        }
    }

    @discardableResult
    func backfillAndCleanupMemoryMetadata(
        removeMarkedLowValueCards: Bool = false,
        limit: Int = 5000
    ) -> MemorySQLiteStore.MetadataCleanupReport {
        do {
            let store = try storeFactory()
            return try store.backfillAndCleanupMetadata(
                removeMarkedLowValueCards: removeMarkedLowValueCards,
                limit: limit
            )
        } catch {
            return MemorySQLiteStore.MetadataCleanupReport(
                scannedCards: 0,
                metadataUpdatedCards: 0,
                lowValueInvalidatedCards: 0,
                removableMarkedCards: 0,
                removedCards: 0
            )
        }
    }

    func runQualityMaintenance() -> MaintenanceResult {
        let report = backfillAndCleanupMemoryMetadata(
            removeMarkedLowValueCards: false,
            limit: 5000
        )
        let updated = report.metadataUpdatedCards
        let invalidated = report.lowValueInvalidatedCards
        let removable = report.removableMarkedCards
        let removed = report.removedCards
        let scanned = report.scannedCards

        let summary = "Scanned \(scanned) card(s), updated metadata for \(updated), invalidated \(invalidated), marked \(removable) removable card(s), removed \(removed)."
        if scanned == 0 && updated == 0 && invalidated == 0 && removable == 0 && removed == 0 {
            return MaintenanceResult(
                didRun: false,
                message: "Quality cleanup/backfill found no eligible data to process. \(summary)"
            )
        }
        return MaintenanceResult(
            didRun: true,
            message: "Quality cleanup/backfill completed. \(summary)"
        )
    }

    func browseIndexedMemories(
        query: String,
        providerID: String?,
        sourceFolderID: String?,
        includePlanContent: Bool = false,
        limit: Int = 80
    ) -> [MemoryIndexedEntry] {
        do {
            let store = try storeFactory()
            let normalizedProviderID = providerID?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedSourceFolderID = sourceFolderID?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let provider = normalizedProviderID.flatMap { rawValue in
                MemoryProviderKind(rawValue: rawValue.lowercased())
            }

            return try store.fetchIndexedEntries(
                query: query,
                provider: provider,
                sourceRootPath: normalizedSourceFolderID,
                includePlanContent: includePlanContent,
                limit: limit
            )
        } catch {
            return []
        }
    }

    func browseRelatedMemories(
        forCardID cardID: UUID,
        includePlanContent: Bool = false,
        limit: Int = 8
    ) -> [MemoryIndexedEntry] {
        do {
            let store = try storeFactory()
            return try store.fetchRelatedIndexedEntries(
                forCardID: cardID,
                includePlanContent: includePlanContent,
                limit: limit
            )
        } catch {
            return []
        }
    }

    func browseIssueTimeline(
        issueKey: String,
        providerID: String?,
        includePlanContent: Bool = false,
        limit: Int = 40
    ) -> [MemoryIndexedEntry] {
        do {
            let store = try storeFactory()
            let normalizedProviderID = providerID?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let provider = normalizedProviderID.flatMap { rawValue in
                MemoryProviderKind(rawValue: rawValue.lowercased())
            }
            return try store.fetchIssueTimelineEntries(
                issueKey: issueKey,
                provider: provider,
                includePlanContent: includePlanContent,
                limit: limit
            )
        } catch {
            return []
        }
    }

    func fetchMemoryAnalytics(limit: Int = 1200) -> MemoryAnalyticsSnapshot {
        do {
            let store = try storeFactory()
            let cards = try store.fetchCardsForRewrite(
                query: "",
                options: MemoryRewriteLookupOptions(
                    provider: nil,
                    includePlanContent: false,
                    limit: max(50, min(limit, 5000))
                )
            )

            struct AttemptRecord: Hashable {
                let providerID: String
                let projectName: String
                let issueKey: String
                let outcomeStatus: String
                let validationState: String
                let invalidatedByAttempt: String
            }

            let attempts: [AttemptRecord] = cards.compactMap { card in
                let issueKey = card.metadata["issue_key"]?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() ?? ""
                guard !issueKey.isEmpty else { return nil }

                let providerID = card.provider.rawValue
                let providerName = MemoryProviderKind(rawValue: providerID)?.displayName ?? providerID
                _ = providerName
                let projectName = normalizedProjectName(from: card.metadata)
                let outcomeStatus = (card.metadata["outcome_status"] ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                let validationState = (card.metadata["validation_state"] ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                let invalidatedByAttempt = (card.metadata["invalidated_by_attempt"] ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                return AttemptRecord(
                    providerID: providerID,
                    projectName: projectName,
                    issueKey: issueKey,
                    outcomeStatus: outcomeStatus,
                    validationState: validationState,
                    invalidatedByAttempt: invalidatedByAttempt
                )
            }

            let totalAttempts = attempts.count
            let invalidatedCount = attempts.filter { $0.validationState == "invalidated" }.count
            let fixedCount = attempts.filter { $0.outcomeStatus == "fixed" }.count
            let repeatedMistakesAvoided = attempts.filter {
                $0.validationState == "invalidated" && !$0.invalidatedByAttempt.isEmpty
            }.count

            var grouped: [String: [AttemptRecord]] = [:]
            for attempt in attempts {
                let groupKey = "\(attempt.providerID)|\(attempt.projectName)"
                grouped[groupKey, default: []].append(attempt)
            }

            let rows: [MemoryAnalyticsBreakdownRow] = grouped.compactMap { groupKey, records in
                let components = groupKey.split(separator: "|", maxSplits: 1).map(String.init)
                guard components.count == 2 else { return nil }
                let providerID = components[0]
                let projectName = components[1]
                let groupTotal = records.count
                guard groupTotal > 0 else { return nil }
                let groupFixed = records.filter { $0.outcomeStatus == "fixed" }.count
                let groupInvalidated = records.filter { $0.validationState == "invalidated" }.count
                let successRate = Double(groupFixed) / Double(groupTotal)

                return MemoryAnalyticsBreakdownRow(
                    id: "\(providerID)|\(projectName)",
                    providerID: providerID,
                    providerName: MemoryProviderKind(rawValue: providerID)?.displayName ?? providerID.capitalized,
                    projectName: projectName,
                    totalAttempts: groupTotal,
                    fixedCount: groupFixed,
                    invalidatedCount: groupInvalidated,
                    successRate: successRate
                )
            }.sorted { lhs, rhs in
                if lhs.totalAttempts == rhs.totalAttempts {
                    return lhs.successRate > rhs.successRate
                }
                return lhs.totalAttempts > rhs.totalAttempts
            }

            let overview = MemoryAnalyticsOverview(
                repeatedMistakesAvoided: repeatedMistakesAvoided,
                invalidationRate: totalAttempts > 0 ? Double(invalidatedCount) / Double(totalAttempts) : 0,
                fixSuccessRate: totalAttempts > 0 ? Double(fixedCount) / Double(totalAttempts) : 0,
                totalTrackedAttempts: totalAttempts
            )

            return MemoryAnalyticsSnapshot(overview: overview, rows: rows)
        } catch {
            return MemoryAnalyticsSnapshot(
                overview: MemoryAnalyticsOverview(
                    repeatedMistakesAvoided: 0,
                    invalidationRate: 0,
                    fixSuccessRate: 0,
                    totalTrackedAttempts: 0
                ),
                rows: []
            )
        }
    }

    private func normalizedProjectName(from metadata: [String: String]) -> String {
        let candidates = [
            metadata["project"],
            metadata["workspace"],
            metadata["repository"]
        ].compactMap { normalizedProjectCandidate($0) }
            .filter { !$0.isEmpty }
        return candidates.first ?? "Unknown"
    }

    private func normalizedProjectCandidate(_ rawValue: String?) -> String? {
        guard var value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }

        value = value.replacingOccurrences(of: "\\", with: "/")
        if let decoded = value.removingPercentEncoding,
           !decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            value = decoded
        }

        if value.contains("/") {
            let components = value
                .split(separator: "/")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            for component in components.reversed() {
                let lowered = component.lowercased()
                if isLikelyFilename(lowered) { continue }
                if isGenericProjectComponent(lowered) { continue }
                if isNumericOrDateLikeComponent(lowered) { continue }
                return component
            }
            return nil
        }

        let collapsed = MemoryTextNormalizer.collapsedWhitespace(value)
        guard !collapsed.isEmpty else { return nil }
        let lowered = collapsed.lowercased()
        if isGenericProjectComponent(lowered) { return nil }
        if isNumericOrDateLikeComponent(lowered) { return nil }
        return collapsed
    }

    private func isGenericProjectComponent(_ value: String) -> Bool {
        let generic: Set<String> = [
            "workspace", "project", "repository", "repo", "unknown", "state", "storage",
            "history", "session", "sessions", "archives", "archive", "users", "user",
            "projects", "repos", "repositories", "tmp", "temp", "default"
        ]
        return generic.contains(value)
    }

    private func isLikelyFilename(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        return value.range(of: "\\.[A-Za-z]{1,8}$", options: .regularExpression) != nil
    }

    private func isNumericOrDateLikeComponent(_ value: String) -> Bool {
        guard !value.isEmpty else { return true }
        if value.range(of: "^[0-9]+$", options: .regularExpression) != nil {
            return true
        }
        let datePatterns = [
            #"^[0-9]{4}[-_.][0-9]{1,2}([\-_.][0-9]{1,2})?$"#,
            #"^[0-9]{8}$"#,
            #"^[0-9]{6}$"#,
            #"^[0-9]{1,2}[-_.][0-9]{1,2}([\-_.][0-9]{2,4})?$"#
        ]
        return datePatterns.contains {
            value.range(of: $0, options: .regularExpression) != nil
        }
    }

    private func queueIndexing(sources: [MemoryDiscoveredSource], rebuild: Bool, clearBeforeIndexing: Bool) {
        activeIndexTask?.cancel()
        activeIndexTaskGeneration += 1
        let generation = activeIndexTaskGeneration
        logger.info(
            "Queue indexing: rebuild=\(rebuild, privacy: .public) clearBeforeIndexing=\(clearBeforeIndexing, privacy: .public) sources=\(sources.count, privacy: .public)"
        )

        activeIndexingRebuild = rebuild
        activeIndexingTotalSources = sources.count
        activeIndexingReport = MemoryIndexingReport()

        let indexingService = self.indexingService
        let storeFactory = self.storeFactory
        let totalSources = sources.count

        activeIndexTask = Task(priority: .utility) {
            let emitProgress: MemoryIndexingService.ProgressHandler = { report, currentSource, currentFilePath in
                if Task.isCancelled {
                    return
                }
                await MainActor.run {
                    guard self.activeIndexTaskGeneration == generation else { return }
                    self.activeIndexingReport = report
                    NotificationCenter.default.post(
                        name: Self.indexingDidProgressNotification,
                        object: nil,
                        userInfo: [
                            IndexingNotificationUserInfoKey.rebuild: rebuild,
                            IndexingNotificationUserInfoKey.totalSources: totalSources,
                            IndexingNotificationUserInfoKey.discoveredSources: report.discoveredSources,
                            IndexingNotificationUserInfoKey.currentSourceDisplayName: currentSource?.displayName ?? "",
                            IndexingNotificationUserInfoKey.currentFilePath: currentFilePath ?? "",
                            IndexingNotificationUserInfoKey.indexedFiles: report.indexedFiles,
                            IndexingNotificationUserInfoKey.skippedFiles: report.skippedFiles,
                            IndexingNotificationUserInfoKey.indexedEvents: report.indexedEvents,
                            IndexingNotificationUserInfoKey.indexedCards: report.indexedCards,
                            IndexingNotificationUserInfoKey.indexedLessons: report.indexedLessons,
                            IndexingNotificationUserInfoKey.indexedRewriteSuggestions: report.indexedRewriteSuggestions,
                            IndexingNotificationUserInfoKey.failureCount: report.failures.count,
                            IndexingNotificationUserInfoKey.firstFailure: report.failures.first ?? ""
                        ]
                    )
                }
            }

            await emitProgress(MemoryIndexingReport(), nil, nil)
            do {
                let store = try storeFactory()
                let report: MemoryIndexingReport
                if clearBeforeIndexing {
                    report = await indexingService.rebuildFromScratch(
                        from: sources,
                        store: store,
                        progress: emitProgress
                    )
                } else if rebuild {
                    report = await indexingService.rebuildIndex(
                        from: sources,
                        store: store,
                        progress: emitProgress
                    )
                } else {
                    report = await indexingService.indexSources(
                        sources,
                        store: store,
                        progress: emitProgress
                    )
                }
                if Task.isCancelled {
                    return
                }
                guard self.activeIndexTaskGeneration == generation else { return }
                self.activeIndexTask = nil
                self.activeIndexingReport = report
                self.postIndexingDidFinishNotification(
                    rebuild: rebuild,
                    cancelled: false,
                    totalSources: totalSources,
                    report: report
                )
                self.logger.info(
                    "Indexing finished: rebuild=\(rebuild, privacy: .public) sources=\(totalSources, privacy: .public) indexedFiles=\(report.indexedFiles, privacy: .public) skippedFiles=\(report.skippedFiles, privacy: .public) indexedCards=\(report.indexedCards, privacy: .public) failures=\(report.failures.count, privacy: .public)"
                )
            } catch {
                if Task.isCancelled {
                    return
                }
                guard self.activeIndexTaskGeneration == generation else { return }
                self.activeIndexTask = nil
                let failureReport = MemoryIndexingReport(
                    failures: [error.localizedDescription]
                )
                self.activeIndexingReport = failureReport
                self.postIndexingDidFinishNotification(
                    rebuild: rebuild,
                    cancelled: false,
                    totalSources: totalSources,
                    report: failureReport
                )
                self.logger.error("Indexing task failed before completion: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
    }

    private func enabledSourcesForIndexing(
        enabledProviderIDs: [String],
        enabledSourceFolderIDs: [String]
    ) -> [MemoryDiscoveredSource] {
        let normalizedProviders = Set(
            enabledProviderIDs.compactMap { providerID -> String? in
                let normalized = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return normalized.isEmpty ? nil : normalized
            }
        )
        guard !normalizedProviders.isEmpty else {
            logger.notice("No source providers are enabled, so no sources are eligible for indexing.")
            return []
        }

        let normalizedFolders = Set(
            enabledSourceFolderIDs.compactMap { folderID -> String? in
                let normalized = folderID.trimmingCharacters(in: .whitespacesAndNewlines)
                return normalized.isEmpty ? nil : normalized
            }
        )

        let discovery = discoveryService.discover(
            enabledProviders: normalizedProviders,
            enabledSourceFolders: normalizedFolders.isEmpty ? nil : normalizedFolders
        )
        if discovery.sources.isEmpty {
            logger.notice("No discovered sources matched enabled source providers/folders.")
        }
        return discovery.sources
    }

    private func postIndexingDidFinishNotification(
        rebuild: Bool,
        cancelled: Bool,
        totalSources: Int,
        report: MemoryIndexingReport
    ) {
        NotificationCenter.default.post(
            name: Self.indexingDidFinishNotification,
            object: nil,
            userInfo: [
                IndexingNotificationUserInfoKey.rebuild: rebuild,
                IndexingNotificationUserInfoKey.cancelled: cancelled,
                IndexingNotificationUserInfoKey.totalSources: totalSources,
                IndexingNotificationUserInfoKey.discoveredSources: report.discoveredSources,
                IndexingNotificationUserInfoKey.indexedFiles: report.indexedFiles,
                IndexingNotificationUserInfoKey.skippedFiles: report.skippedFiles,
                IndexingNotificationUserInfoKey.indexedEvents: report.indexedEvents,
                IndexingNotificationUserInfoKey.indexedCards: report.indexedCards,
                IndexingNotificationUserInfoKey.indexedLessons: report.indexedLessons,
                IndexingNotificationUserInfoKey.indexedRewriteSuggestions: report.indexedRewriteSuggestions,
                IndexingNotificationUserInfoKey.failureCount: report.failures.count,
                IndexingNotificationUserInfoKey.firstFailure: report.failures.first ?? ""
            ]
        )
    }

    private static func makeProvider(_ provider: MemoryDiscoveredProvider) -> Provider {
        Provider(
            id: provider.id,
            name: provider.name,
            detail: provider.detail,
            sourceCount: provider.sourceCount
        )
    }

    private static func makeSourceFolder(_ source: MemoryDiscoveredSourceFolder) -> SourceFolder {
        SourceFolder(
            id: source.id,
            name: source.name,
            path: source.path,
            providerID: source.providerID
        )
    }
}
