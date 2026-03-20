import Foundation
import XCTest
@testable import OpenAssist

final class ScheduledJobStoreTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        let fileManager = FileManager.default
        for directory in temporaryDirectories {
            try? fileManager.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testScheduledJobStorePersistsLatestRunFieldsAndRunHistory() throws {
        let databaseURL = try makeDatabaseURL()
        let store = try ScheduledJobStore(databaseURL: databaseURL)

        let startedAt = Date(timeIntervalSince1970: 10_000)
        let firstIssueAt = Date(timeIntervalSince1970: 10_020)
        let finishedAt = Date(timeIntervalSince1970: 10_090)

        var job = ScheduledJob.make(
            name: "Teams checker",
            prompt: "Check the latest Teams chat",
            jobType: .general,
            recurrence: .daily
        )
        job.dedicatedSessionID = "session-1"
        job.lastRunAt = finishedAt
        job.lastRunNote = "Failed after opening a preview instead of the real thread."
        job.lastRunOutcome = .failed
        job.lastRunStartedAt = startedAt
        job.lastRunFinishedAt = finishedAt
        job.lastRunFirstIssueAt = firstIssueAt
        job.lastRunSummary = "The automation opened a preview and then stopped before it reached the real thread."
        job.lastLearnedLessonCount = 2

        try store.insertOrUpdate(job)

        var run = ScheduledJobRun.make(
            jobID: job.id,
            sessionID: "session-1",
            startedAt: startedAt
        )
        run.finishedAt = finishedAt
        run.outcome = .failed
        run.firstIssueAt = firstIssueAt
        run.statusNote = "Failed after opening a preview instead of the real thread."
        run.summaryText = "The automation opened a preview and then stopped before it reached the real thread."
        run.learnedLessonCount = 2
        try store.insertOrUpdateRun(run)

        let loadedJob = try XCTUnwrap(store.fetchAll().first(where: { $0.id == job.id }))
        XCTAssertEqual(loadedJob.dedicatedSessionID, "session-1")
        XCTAssertEqual(loadedJob.lastRunOutcome, .failed)
        XCTAssertEqual(loadedJob.lastRunStartedAt, startedAt)
        XCTAssertEqual(loadedJob.lastRunFinishedAt, finishedAt)
        XCTAssertEqual(loadedJob.lastRunFirstIssueAt, firstIssueAt)
        XCTAssertEqual(loadedJob.lastRunSummary, "The automation opened a preview and then stopped before it reached the real thread.")
        XCTAssertEqual(loadedJob.lastLearnedLessonCount, 2)

        let loadedRuns = try store.fetchRuns(jobID: job.id, limit: 10)
        XCTAssertEqual(loadedRuns.count, 1)
        XCTAssertEqual(loadedRuns[0].sessionID, "session-1")
        XCTAssertEqual(loadedRuns[0].outcome, .failed)
        XCTAssertEqual(loadedRuns[0].firstIssueAt, firstIssueAt)
        XCTAssertEqual(loadedRuns[0].summaryText, "The automation opened a preview and then stopped before it reached the real thread.")
        XCTAssertEqual(loadedRuns[0].learnedLessonCount, 2)

        try store.delete(id: job.id)
        XCTAssertTrue(try store.fetchAll().isEmpty)
        XCTAssertTrue(try store.fetchRuns(jobID: job.id, limit: 10).isEmpty)
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    private func makeDatabaseURL() throws -> URL {
        let directory = try makeTemporaryDirectory(named: "scheduled-jobs-db")
        return directory.appendingPathComponent("scheduled-jobs.sqlite", isDirectory: false)
    }
}
