import Foundation

struct AutomationRunProcessingResult: Sendable {
    let statusNote: String
    let summaryText: String?
    let firstIssueAt: Date?
    let learnedLessonCount: Int
}

final class AutomationMemoryService {
    static let shared = AutomationMemoryService()

    private struct AutomationLessonCandidate: Hashable {
        let title: String
        let summary: String
        let detail: String
        let keywords: [String]
        let confidence: Double
        let lessonKey: String?
        let metadata: [String: String]
    }

    private let store: MemorySQLiteStore
    private let memoryRetrievalService: AssistantMemoryRetrievalService
    private let rewriteProvider: MemoryRewriteExtractionProviding

    init(
        store: MemorySQLiteStore? = nil,
        memoryRetrievalService: AssistantMemoryRetrievalService? = nil,
        rewriteProvider: MemoryRewriteExtractionProviding = StubMemoryRewriteExtractionProvider.shared
    ) {
        let resolvedStore = store ?? (try? MemorySQLiteStore()) ?? MemorySQLiteStore.fallback()
        self.store = resolvedStore
        self.memoryRetrievalService = memoryRetrievalService ?? AssistantMemoryRetrievalService(store: resolvedStore)
        self.rewriteProvider = rewriteProvider
    }

    func prepareAutomationTurnContext(
        job: ScheduledJob,
        threadID: String,
        prompt: String,
        cwd: String?,
        summaryMaxChars: Int
    ) throws -> AssistantBuiltMemoryContext {
        try memoryRetrievalService.prepareTurnContext(
            threadID: threadID,
            prompt: prompt,
            cwd: cwd,
            summaryMaxChars: summaryMaxChars,
            longTermScope: automationScopeContext(for: job, cwd: cwd),
            statusBase: "Using automation memory"
        )
    }

    func activeLessons(for job: ScheduledJob, cwd: String?) -> [AssistantMemoryEntry] {
        let scope = automationScopeContext(for: job, cwd: cwd)
        return (try? store.fetchAssistantMemoryEntries(
            query: "",
            provider: .codex,
            scopeKey: scope.scopeKey,
            projectKey: scope.projectKey,
            identityKey: scope.identityKey,
            state: .active,
            limit: 12
        )) ?? []
    }

    func processCompletedRun(
        job: ScheduledJob,
        run: ScheduledJobRun,
        transcript: [AssistantTranscriptEntry],
        timeline: [AssistantTimelineItem],
        cwd: String?
    ) async -> AutomationRunProcessingResult {
        let scope = automationScopeContext(for: job, cwd: cwd)
        let relevantTranscript = transcript.filter { $0.createdAt >= run.startedAt }
        let relevantTimeline = timeline.filter { $0.sortDate >= run.startedAt }
        let firstIssueAt = resolvedFirstIssueAt(
            explicitValue: run.firstIssueAt,
            transcript: relevantTranscript,
            timeline: relevantTimeline,
            outcome: run.outcome,
            fallback: run.finishedAt
        )
        let finishedAt = run.finishedAt ?? Date()
        let summarySeed = buildSummarySeed(
            job: job,
            run: run,
            transcript: relevantTranscript,
            timeline: relevantTimeline,
            firstIssueAt: firstIssueAt,
            finishedAt: finishedAt
        )
        let summaryText = await summarizedRunText(
            job: job,
            run: run,
            scope: scope,
            seed: summarySeed
        )
        let lessonCount = await persistLessons(
            from: summaryText ?? summarySeed,
            job: job,
            run: run,
            scope: scope,
            transcript: relevantTranscript,
            timeline: relevantTimeline
        )

        return AutomationRunProcessingResult(
            statusNote: statusNote(
                for: run.outcome,
                firstIssueAt: firstIssueAt,
                learnedLessonCount: lessonCount
            ),
            summaryText: summaryText ?? summarySeed,
            firstIssueAt: firstIssueAt,
            learnedLessonCount: lessonCount
        )
    }

    private func automationScopeContext(for job: ScheduledJob, cwd: String?) -> MemoryScopeContext {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.developingadventures.OpenAssist"
        let normalizedCWD = cwd?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let projectName = normalizedCWD.flatMap { path in
            URL(fileURLWithPath: path, isDirectory: true).lastPathComponent.nonEmpty
        }
        let projectKey = projectName.map {
            "project:" + MemoryTextNormalizer.collapsedWhitespace($0).lowercased()
        }

        return MemoryScopeContext(
            appName: "Open Assist",
            bundleID: bundleID,
            surfaceLabel: "Automation",
            projectKey: projectKey,
            projectName: projectName,
            repositoryName: projectName,
            identityKey: "assistant-automation:\(job.id.lowercased())",
            identityType: "assistant-automation",
            identityLabel: job.name,
            isCodingContext: projectName != nil
        )
    }

    private func resolvedFirstIssueAt(
        explicitValue: Date?,
        transcript: [AssistantTranscriptEntry],
        timeline: [AssistantTimelineItem],
        outcome: ScheduledJobRunOutcome?,
        fallback: Date?
    ) -> Date? {
        if let explicitValue {
            return explicitValue
        }

        let transcriptIssue = transcript
            .filter { $0.role == .error || ($0.role == .system && $0.emphasis) }
            .map(\.createdAt)
            .min()

        let timelineIssue = timeline.compactMap { item -> Date? in
            if item.kind == .system, item.emphasis {
                return item.createdAt
            }
            guard let activity = item.activity,
                  activity.status == .failed || activity.status == .interrupted else {
                return nil
            }
            return activity.startedAt
        }
        .min()

        let fallbackIssue = outcome == .completed ? nil : fallback

        return [transcriptIssue, timelineIssue, fallbackIssue]
            .compactMap { $0 }
            .min()
    }

    private func buildSummarySeed(
        job: ScheduledJob,
        run: ScheduledJobRun,
        transcript: [AssistantTranscriptEntry],
        timeline: [AssistantTimelineItem],
        firstIssueAt: Date?,
        finishedAt: Date
    ) -> String {
        let outcomeLabel = run.outcome?.displayName ?? "Unknown"
        let userPrompt = transcript.first(where: { $0.role == .user })?.text.nonEmpty ?? job.prompt
        let finalAssistantText = transcript.last(where: {
            $0.role == .assistant || $0.role == .error || $0.role == .status || $0.role == .system
        })?.text.nonEmpty

        let notableSteps = timeline.compactMap { item -> String? in
            if let activity = item.activity {
                switch activity.status {
                case .failed, .interrupted:
                    return "\(activity.status.rawValue.capitalized): \(activity.friendlySummary)"
                case .completed:
                    return activity.kind == .browserAutomation || activity.kind == .commandExecution
                        ? activity.friendlySummary
                        : nil
                case .pending, .running, .waiting:
                    return nil
                }
            }
            if item.kind == .system, let text = item.text?.nonEmpty {
                return text
            }
            return nil
        }
        .uniqued()
        .prefix(4)

        var lines: [String] = [
            "Automation: \(job.name)",
            "Outcome: \(outcomeLabel)",
            "Started: \(formattedTimestamp(run.startedAt))",
            "Finished: \(formattedTimestamp(finishedAt))"
        ]
        if let firstIssueAt {
            lines.append("First issue: \(formattedTimestamp(firstIssueAt))")
        }
        lines.append("Prompt: \(userPrompt)")
        if let finalAssistantText {
            lines.append("Final result: \(finalAssistantText)")
        }
        if !notableSteps.isEmpty {
            lines.append("Notable steps:\n" + notableSteps.map { "- \($0)" }.joined(separator: "\n"))
        }
        return lines.joined(separator: "\n")
    }

    private func summarizedRunText(
        job: ScheduledJob,
        run: ScheduledJobRun,
        scope: MemoryScopeContext,
        seed: String
    ) async -> String? {
        let recentTurns = [
            PromptRewriteConversationTurn(
                userText: job.prompt,
                assistantText: seed,
                timestamp: run.finishedAt ?? run.startedAt
            )
        ]
        let context = PromptRewriteConversationContext(
            id: "automation:\(job.id)",
            appName: "Open Assist",
            bundleIdentifier: scope.bundleID,
            screenLabel: "Automation",
            fieldLabel: job.name,
            logicalSurfaceKey: "automation:\(job.id)",
            projectKey: scope.projectKey,
            projectLabel: scope.projectName,
            identityKey: scope.identityKey,
            identityType: scope.identityType,
            identityLabel: scope.identityLabel,
            nativeThreadKey: run.sessionID
        )
        let response = await rewriteProvider.summarizeConversationHandoff(
            summarySeed: seed,
            recentTurns: recentTurns,
            context: context,
            timeoutSeconds: 20
        )
        return MemoryTextNormalizer.normalizedBody(response.text).nonEmpty
    }

    private func persistLessons(
        from summaryText: String,
        job: ScheduledJob,
        run: ScheduledJobRun,
        scope: MemoryScopeContext,
        transcript: [AssistantTranscriptEntry],
        timeline: [AssistantTimelineItem]
    ) async -> Int {
        let runText = ([summaryText] + transcript.map(\.text) + timeline.compactMap { item in
            item.activity?.friendlySummary ?? item.text
        })
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty }
            .joined(separator: "\n")

        var candidates = heuristicCandidates(
            from: runText,
            summaryText: summaryText,
            outcome: run.outcome
        )

        if let aiCandidate = await aiLessonCandidate(
            summaryText: summaryText,
            job: job,
            run: run,
            scope: scope
        ) {
            candidates.append(aiCandidate)
        }

        let mergedCandidates = dedupedCandidates(candidates)
        guard !mergedCandidates.isEmpty else { return 0 }

        var savedCount = 0
        for candidate in mergedCandidates.prefix(2) {
            if save(candidate, scope: scope, threadID: run.sessionID, job: job) {
                savedCount += 1
            }
        }
        return savedCount
    }

    private func heuristicCandidates(
        from runText: String,
        summaryText: String,
        outcome: ScheduledJobRunOutcome?
    ) -> [AutomationLessonCandidate] {
        let lower = runText.lowercased()
        let progressVerbCount = countMatches(
            pattern: "\\b(checking|trying|switching|looking|opening|reading|found|next|now|inspecting|confirming)\\b",
            in: lower
        )
        let firstPersonCount = countMatches(
            pattern: "\\b(i'm|i am|i'll|i will)\\b",
            in: lower
        )
        let toolLikeCount = countMatches(
            pattern: "\\b(command|search|view image|screenshot|browser|tool)\\b",
            in: lower
        )

        var results: [AutomationLessonCandidate] = []
        let narrationHeavy = progressVerbCount >= 6
            && firstPersonCount >= 3
            && (runText.count >= 700 || toolLikeCount >= 8)
        if narrationHeavy {
            results.append(
                lessonCandidate(
                    summary: "For simple automation tasks, keep progress updates short and move to the answer faster instead of narrating every step.",
                    detail: "The run spent too much space on status narration. Prefer shorter updates and faster task completion.",
                    confidence: 0.82,
                    lessonKey: "narration_too_long"
                )
            )
        }

        if lower.contains("brave") && lower.contains("apple events") && lower.contains("javascript") {
            results.append(
                lessonCandidate(
                    summary: "For browser tasks in Brave, check whether 'Allow JavaScript from Apple Events' is enabled before relying on page scripting.",
                    detail: "This run suggests browser scripting was blocked. Verify Brave Apple Events support first, then continue.",
                    confidence: 0.84,
                    lessonKey: "brave_apple_events"
                )
            )
        }

        if lower.contains("permission") || lower.contains("approve") || lower.contains("user input") {
            results.append(
                lessonCandidate(
                    summary: "Ask for missing permission or user input earlier, before spending many tool calls on uncertain workarounds.",
                    detail: "This run hit a permission or confirmation blocker. Ask earlier instead of continuing low-confidence retries.",
                    confidence: 0.83,
                    lessonKey: "ask_permission_earlier"
                )
            )
        }

        if lower.contains("preview") && lower.contains("thread")
            && (lower.contains("instead") || lower.contains("directly") || lower.contains("real")) {
            results.append(
                lessonCandidate(
                    summary: "If search opens a preview instead of the real target, open the real target item directly before reading or acting on it.",
                    detail: "The run learned that preview content was not enough. Open the real item or thread before summarizing or continuing.",
                    confidence: outcome == .completed ? 0.86 : 0.76,
                    lessonKey: "open_real_target_not_preview"
                )
            )
        }

        if (lower.contains("switching") || lower.contains("detour") || lower.contains("workaround") || lower.contains("instead"))
            && progressVerbCount >= 4 {
            results.append(
                lessonCandidate(
                    summary: "When the current path looks blocked, ask earlier instead of trying many detours.",
                    detail: "The run spent too long switching between low-confidence paths. Prefer an earlier clarification or permission request.",
                    confidence: 0.78,
                    lessonKey: "ask_earlier_when_blocked"
                )
            )
        }

        if outcome == .completed, !containsCorrectiveSignal(summaryText) {
            results.removeAll { $0.lessonKey == "ask_earlier_when_blocked" || $0.lessonKey == "ask_permission_earlier" }
        }

        return results
    }

    private func aiLessonCandidate(
        summaryText: String,
        job: ScheduledJob,
        run: ScheduledJobRun,
        scope: MemoryScopeContext
    ) async -> AutomationLessonCandidate? {
        let body = """
        Automation run summary:
        \(summaryText)

        If there is a stable mistake-to-better-approach lesson here, describe it as:
        before -> after
        """
        let metadata = [
            "memory_domain": "assistant",
            "automation_job_id": job.id,
            "automation_job_name": job.name,
            "scope_key": scope.scopeKey,
            "run_outcome": run.outcome?.rawValue ?? "unknown"
        ]
        let draft = MemoryEventDraft(
            kind: .rewrite,
            title: "Automation lesson for \(job.name)",
            body: body,
            timestamp: run.finishedAt ?? run.startedAt,
            nativeSummary: summaryText,
            keywords: MemoryTextNormalizer.keywords(from: summaryText, limit: 12),
            metadata: metadata
        )
        let placeholderID = UUID()
        let card = MemoryCard(
            id: placeholderID,
            sourceID: placeholderID,
            sourceFileID: placeholderID,
            eventID: placeholderID,
            provider: .codex,
            title: "Automation lesson",
            summary: MemoryTextNormalizer.normalizedSummary(summaryText, limit: 220),
            detail: body,
            keywords: draft.keywords,
            score: 0.8,
            createdAt: run.startedAt,
            updatedAt: run.finishedAt ?? run.startedAt,
            isPlanContent: false,
            metadata: metadata
        )

        guard let lesson = await rewriteProvider.lesson(for: draft, card: card, provider: .codex) else {
            return nil
        }
        if run.outcome == .completed, !containsCorrectiveSignal(summaryText) {
            return nil
        }
        guard lesson.validationConfidence >= (run.outcome == .completed ? 0.68 : 0.58) else {
            return nil
        }

        let improvedPrompt = MemoryTextNormalizer.normalizedBody(lesson.improvedPrompt)
        let mistakePattern = MemoryTextNormalizer.normalizedBody(lesson.mistakePattern)
        guard let summary = improvedPrompt.nonEmpty else { return nil }
        guard let detail = """
        Avoid: \(mistakePattern)

        Better approach: \(improvedPrompt)

        Why: \(lesson.rationale)
        """.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return nil
        }

        return AutomationLessonCandidate(
            title: MemoryTextNormalizer.normalizedTitle(summary, fallback: "Automation Lesson"),
            summary: summary,
            detail: detail,
            keywords: MemoryTextNormalizer.keywords(from: "\(mistakePattern) \(improvedPrompt)", limit: 12),
            confidence: lesson.validationConfidence,
            lessonKey: aiLessonKey(from: mistakePattern),
            metadata: lesson.sourceMetadata
        )
    }

    private func save(
        _ candidate: AutomationLessonCandidate,
        scope: MemoryScopeContext,
        threadID: String?,
        job: ScheduledJob
    ) -> Bool {
        do {
            let existing = try store.fetchAssistantMemoryEntries(
                query: "",
                provider: .codex,
                scopeKey: scope.scopeKey,
                projectKey: scope.projectKey,
                identityKey: scope.identityKey,
                state: .active,
                limit: 50
            )

            let normalizedSummary = normalizedKey(candidate.summary)
            if existing.contains(where: { normalizedKey($0.summary) == normalizedSummary }) {
                return false
            }

            if let lessonKey = candidate.lessonKey?.nonEmpty {
                for entry in existing where entry.metadata["automation_lesson_key"] == lessonKey {
                    try store.invalidateAssistantMemoryEntry(
                        id: entry.id,
                        reason: "Superseded by a newer lesson for the same automation pattern."
                    )
                }
            }

            var metadata = candidate.metadata
            metadata["memory_domain"] = "assistant"
            metadata["automation_job_id"] = job.id
            metadata["automation_job_name"] = job.name
            metadata["scope_key"] = scope.scopeKey
            metadata["identity_key"] = scope.identityKey ?? ""
            if let lessonKey = candidate.lessonKey?.nonEmpty {
                metadata["automation_lesson_key"] = lessonKey
            }

            let entry = AssistantMemoryEntry(
                provider: .codex,
                scopeKey: scope.scopeKey,
                bundleID: scope.bundleID,
                projectKey: scope.projectKey,
                identityKey: scope.identityKey,
                threadID: threadID,
                memoryType: .lesson,
                title: candidate.title,
                summary: candidate.summary,
                detail: candidate.detail,
                keywords: candidate.keywords,
                confidence: candidate.confidence,
                metadata: metadata
            )
            try store.upsertAssistantMemoryEntry(entry)
            return true
        } catch {
            CrashReporter.logWarning("Automation lesson save failed for job \(job.id): \(error.localizedDescription)")
            return false
        }
    }

    private func dedupedCandidates(_ candidates: [AutomationLessonCandidate]) -> [AutomationLessonCandidate] {
        var seen: Set<String> = []
        var output: [AutomationLessonCandidate] = []
        for candidate in candidates {
            let key = candidate.lessonKey?.nonEmpty ?? normalizedKey(candidate.summary)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            output.append(candidate)
        }
        return output
            .sorted { lhs, rhs in
                if lhs.confidence == rhs.confidence {
                    return lhs.summary.count > rhs.summary.count
                }
                return lhs.confidence > rhs.confidence
            }
    }

    private func lessonCandidate(
        summary: String,
        detail: String,
        confidence: Double,
        lessonKey: String
    ) -> AutomationLessonCandidate {
        let normalizedSummary = MemoryTextNormalizer.normalizedSummary(summary, limit: 220)
        let normalizedDetail = MemoryTextNormalizer.normalizedBody(detail)
        return AutomationLessonCandidate(
            title: MemoryTextNormalizer.normalizedTitle(normalizedSummary, fallback: "Automation Lesson"),
            summary: normalizedSummary,
            detail: normalizedDetail,
            keywords: MemoryTextNormalizer.keywords(from: "\(normalizedSummary) \(normalizedDetail)", limit: 12),
            confidence: confidence,
            lessonKey: lessonKey,
            metadata: ["lesson_source": "heuristic"]
        )
    }

    private func containsCorrectiveSignal(_ text: String) -> Bool {
        let lower = text.lowercased()
        let signals = ["instead", "rather than", "avoid", "before", "after", "directly", "real target", "preview"]
        return signals.contains(where: lower.contains)
    }

    private func aiLessonKey(from mistakePattern: String) -> String {
        let keywords = MemoryTextNormalizer.keywords(from: mistakePattern, limit: 6)
        if keywords.isEmpty {
            return "ai:" + normalizedKey(mistakePattern)
        }
        return "ai:" + keywords.joined(separator: "-")
    }

    private func statusNote(
        for outcome: ScheduledJobRunOutcome?,
        firstIssueAt: Date?,
        learnedLessonCount: Int
    ) -> String {
        let base = outcome?.displayName ?? "Finished"
        var segments = [base]
        if firstIssueAt != nil, outcome != .completed {
            segments.append("issue captured")
        }
        if learnedLessonCount > 0 {
            segments.append("saved \(learnedLessonCount) lesson\(learnedLessonCount == 1 ? "" : "s")")
        }
        return segments.joined(separator: " · ")
    }

    private func formattedTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func normalizedKey(_ value: String) -> String {
        MemoryTextNormalizer.collapsedWhitespace(value).lowercased()
    }

    private func countMatches(pattern: String, in text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return 0
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.numberOfMatches(in: text, options: [], range: range)
    }
}

private extension Array where Element == String {
    func uniqued() -> [String] {
        var seen: Set<String> = []
        var output: [String] = []
        for value in self {
            let key = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            output.append(value)
        }
        return output
    }
}
