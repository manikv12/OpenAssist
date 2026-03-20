import Foundation
import XCTest
@testable import OpenAssist

final class AutomationMemoryServiceTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        let fileManager = FileManager.default
        for directory in temporaryDirectories {
            try? fileManager.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testAutomationLessonsStayScopedToJob() async throws {
        let memoryRoot = try makeTemporaryDirectory(named: "automation-memory")
        let databaseURL = try makeDatabaseURL()
        let store = try MemorySQLiteStore(databaseURL: databaseURL)
        let retrievalService = AssistantMemoryRetrievalService(
            store: store,
            threadMemoryService: AssistantThreadMemoryService(baseDirectoryURL: memoryRoot)
        )
        let provider = SequencedAutomationRewriteProvider(
            summaries: [
                "After the search opened a preview instead of the real thread, the automation opened the real target directly and finished successfully."
            ],
            lessons: []
        )
        let service = AutomationMemoryService(
            store: store,
            memoryRetrievalService: retrievalService,
            rewriteProvider: provider
        )

        let jobA = ScheduledJob.make(
            name: "Teams checker",
            prompt: "Check the latest Teams chat",
            jobType: .general,
            recurrence: .daily
        )
        let jobB = ScheduledJob.make(
            name: "Email checker",
            prompt: "Check the latest email",
            jobType: .general,
            recurrence: .daily
        )

        var run = ScheduledJobRun.make(
            jobID: jobA.id,
            sessionID: "thread-a",
            startedAt: Date(timeIntervalSince1970: 1_000)
        )
        run.finishedAt = Date(timeIntervalSince1970: 1_120)
        run.outcome = .completed

        let transcript = [
            AssistantTranscriptEntry(role: .user, text: jobA.prompt, createdAt: run.startedAt),
            AssistantTranscriptEntry(
                role: .assistant,
                text: "The search opened a preview instead of the real thread, so I opened the real target directly before I read it.",
                createdAt: Date(timeIntervalSince1970: 1_090)
            )
        ]

        let result = await service.processCompletedRun(
            job: jobA,
            run: run,
            transcript: transcript,
            timeline: [],
            cwd: "/tmp/OpenAssist"
        )

        XCTAssertEqual(result.learnedLessonCount, 1)

        let lessonsForJobA = service.activeLessons(for: jobA, cwd: "/tmp/OpenAssist")
        XCTAssertEqual(lessonsForJobA.count, 1)
        XCTAssertTrue(lessonsForJobA[0].summary.contains("open the real target item directly"))

        let lessonsForJobB = service.activeLessons(for: jobB, cwd: "/tmp/OpenAssist")
        XCTAssertTrue(lessonsForJobB.isEmpty)

        let storedEntries = try store.fetchAssistantMemoryEntries(
            query: "",
            provider: .codex,
            scopeKey: lessonsForJobA[0].scopeKey,
            projectKey: lessonsForJobA[0].projectKey,
            identityKey: lessonsForJobA[0].identityKey,
            state: .active,
            limit: 10
        )
        XCTAssertEqual(storedEntries.count, 1)
        XCTAssertEqual(storedEntries[0].metadata["automation_job_id"], jobA.id)
    }

    func testAutomationLessonReplacementInvalidatesOlderLesson() async throws {
        let memoryRoot = try makeTemporaryDirectory(named: "automation-memory")
        let databaseURL = try makeDatabaseURL()
        let store = try MemorySQLiteStore(databaseURL: databaseURL)
        let retrievalService = AssistantMemoryRetrievalService(
            store: store,
            threadMemoryService: AssistantThreadMemoryService(baseDirectoryURL: memoryRoot)
        )
        let provider = SequencedAutomationRewriteProvider(
            summaries: [
                "Before the fix, the automation used a weak path. After the fix, it used a stronger direct path.",
                "Before the fix, the automation used a weak path. After the fix, it used an even better direct path."
            ],
            lessons: [
                MemoryLessonDraft(
                    mistakePattern: "opening only the search preview instead of the real result",
                    improvedPrompt: "Open the real target directly before reading the conversation.",
                    rationale: "The preview does not always contain the full thread.",
                    validationConfidence: 0.82
                ),
                MemoryLessonDraft(
                    mistakePattern: "opening only the search preview instead of the real result",
                    improvedPrompt: "If the preview is incomplete, open the search result itself and continue there.",
                    rationale: "The newer successful run showed a better direct path.",
                    validationConfidence: 0.88
                )
            ]
        )
        let service = AutomationMemoryService(
            store: store,
            memoryRetrievalService: retrievalService,
            rewriteProvider: provider
        )

        let job = ScheduledJob.make(
            name: "Teams checker",
            prompt: "Check the latest Teams chat",
            jobType: .general,
            recurrence: .daily
        )

        var firstRun = ScheduledJobRun.make(
            jobID: job.id,
            sessionID: "thread-a",
            startedAt: Date(timeIntervalSince1970: 2_000)
        )
        firstRun.finishedAt = Date(timeIntervalSince1970: 2_060)
        firstRun.outcome = .completed

        _ = await service.processCompletedRun(
            job: job,
            run: firstRun,
            transcript: [AssistantTranscriptEntry(role: .assistant, text: "Used a first direct path.", createdAt: Date(timeIntervalSince1970: 2_050))],
            timeline: [],
            cwd: "/tmp/OpenAssist"
        )

        var secondRun = ScheduledJobRun.make(
            jobID: job.id,
            sessionID: "thread-a",
            startedAt: Date(timeIntervalSince1970: 3_000)
        )
        secondRun.finishedAt = Date(timeIntervalSince1970: 3_090)
        secondRun.outcome = .completed

        let secondResult = await service.processCompletedRun(
            job: job,
            run: secondRun,
            transcript: [AssistantTranscriptEntry(role: .assistant, text: "Used a better direct path.", createdAt: Date(timeIntervalSince1970: 3_080))],
            timeline: [],
            cwd: "/tmp/OpenAssist"
        )

        XCTAssertEqual(secondResult.learnedLessonCount, 1)

        let activeLessons = service.activeLessons(for: job, cwd: "/tmp/OpenAssist")
        XCTAssertEqual(activeLessons.count, 1)
        let activeLesson = try XCTUnwrap(activeLessons.first)
        XCTAssertTrue(activeLesson.summary.contains("open the search result itself"))

        let invalidatedLessons = try store.fetchAssistantMemoryEntries(
            query: "",
            provider: .codex,
            scopeKey: activeLesson.scopeKey,
            projectKey: activeLesson.projectKey,
            identityKey: activeLesson.identityKey,
            state: .invalidated,
            limit: 10
        )
        XCTAssertEqual(invalidatedLessons.count, 1)
        let invalidatedLesson = try XCTUnwrap(invalidatedLessons.first)
        XCTAssertTrue(invalidatedLesson.summary.contains("Open the real target directly"))
        XCTAssertTrue((invalidatedLesson.metadata["invalidation_reason"] ?? "").contains("Superseded"))
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    private func makeDatabaseURL() throws -> URL {
        let directory = try makeTemporaryDirectory(named: "automation-memory-db")
        return directory.appendingPathComponent("memory.sqlite", isDirectory: false)
    }
}

private final class SequencedAutomationRewriteProvider: MemoryRewriteExtractionProviding {
    private let storage: Storage

    init(summaries: [String], lessons: [MemoryLessonDraft]) {
        storage = Storage(summaries: summaries, lessons: lessons)
    }

    func summary(
        for draft: MemoryEventDraft,
        provider: MemoryProviderKind
    ) async -> String? {
        _ = draft
        _ = provider
        return nil
    }

    func rewriteSuggestion(
        for draft: MemoryEventDraft,
        card: MemoryCard,
        provider: MemoryProviderKind
    ) async -> RewriteSuggestion? {
        _ = draft
        _ = card
        _ = provider
        return nil
    }

    func lesson(
        for draft: MemoryEventDraft,
        card: MemoryCard,
        provider: MemoryProviderKind
    ) async -> MemoryLessonDraft? {
        _ = draft
        _ = card
        _ = provider
        return await storage.nextLesson()
    }

    func summarizeConversationHandoff(
        summarySeed: String,
        recentTurns: [PromptRewriteConversationTurn],
        context: PromptRewriteConversationContext,
        timeoutSeconds: Int
    ) async -> (text: String, confidence: Double?, method: String) {
        _ = recentTurns
        _ = context
        _ = timeoutSeconds
        if let summary = await storage.nextSummary() {
            return (summary, 0.9, "test")
        }
        return (MemoryTextNormalizer.normalizedBody(summarySeed), nil, "fallback")
    }

    func hasAIBackedIndexingAccess(for provider: MemoryProviderKind) async -> Bool {
        _ = provider
        return false
    }

    private actor Storage {
        var summaries: [String]
        var lessons: [MemoryLessonDraft]

        init(summaries: [String], lessons: [MemoryLessonDraft]) {
            self.summaries = summaries
            self.lessons = lessons
        }

        func nextSummary() -> String? {
            guard !summaries.isEmpty else { return nil }
            return summaries.removeFirst()
        }

        func nextLesson() -> MemoryLessonDraft? {
            guard !lessons.isEmpty else { return nil }
            return lessons.removeFirst()
        }
    }
}
