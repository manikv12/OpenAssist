import AppKit
import Foundation

/// Manages scheduled jobs: persistence, timer-based firing, and serialized execution.
///
/// All jobs currently share the same assistant runtime, so they must execute one at a time.
/// Job type is still stored for UI and future routing, but execution is globally queued today.
@MainActor
final class JobQueueCoordinator: ObservableObject {
    static let shared = JobQueueCoordinator()

    @Published private(set) var jobs: [ScheduledJob] = []
    @Published private(set) var runningJobIDs: Set<String> = []
    @Published private(set) var runsByJobID: [String: [ScheduledJobRun]] = [:]
    @Published private(set) var automationLessonsByJobID: [String: [AssistantMemoryEntry]] = [:]

    private var store: ScheduledJobStore?
    private let automationMemoryService = AutomationMemoryService.shared
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var hasStarted = false
    private var pendingExecutions: [PendingExecution] = []
    private var pendingExecutionJobIDs: Set<String> = []
    private var activeExecution: PendingExecution?
    private var activeRunsByJobID: [String: ScheduledJobRun] = [:]

    private init() {}

    private struct PendingExecution: Equatable {
        let jobID: String
        let allowsDisabledExecution: Bool
    }

    // MARK: - Lifecycle

    func start() {
        guard !hasStarted else {
            refreshSchedule()
            return
        }
        hasStarted = true

        do {
            store = try ScheduledJobStore()
            jobs = (try? store?.fetchAll()) ?? []
            reloadDerivedState()
        } catch {
            CrashReporter.logError("JobQueueCoordinator: failed to open store: \(error)")
        }

        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshSchedule()
                }
            }
        }

        refreshSchedule()
    }

    // MARK: - Public API

    func addJob(_ job: ScheduledJob) {
        jobs.append(job)
        try? store?.insertOrUpdate(job)
        reloadDerivedState(for: job.id)
        refreshSchedule()
    }

    func updateJob(_ job: ScheduledJob) {
        if let idx = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[idx] = job
        } else {
            jobs.append(job)
        }
        try? store?.insertOrUpdate(job)
        reloadDerivedState(for: job.id)
        refreshSchedule()
    }

    func removeJob(id: String) {
        guard !runningJobIDs.contains(id) else { return }
        jobs.removeAll { $0.id == id }
        pendingExecutions.removeAll { $0.jobID == id }
        pendingExecutionJobIDs.remove(id)
        try? store?.delete(id: id)
        runsByJobID[id] = nil
        automationLessonsByJobID[id] = nil
        activeRunsByJobID[id] = nil
        scheduleNextTimer()
    }

    func runJobNow(_ job: ScheduledJob) {
        enqueue(jobID: job.id, allowsDisabledExecution: true)
    }

    func refreshSchedule() {
        fireDueJobs()
        scheduleNextTimer()
    }

    func markJobExecutionFinished(id: String) {
        guard activeExecution?.jobID == id else { return }
        activeExecution = nil
        runningJobIDs.remove(id)
        startNextQueuedExecutionIfPossible()
    }

    /// Records the outcome of a job execution and persists it.
    func recordJobResult(id: String, note: String, sessionID: String? = nil) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[idx].lastRunNote = note
        if let sessionID {
            jobs[idx].dedicatedSessionID = sessionID
        }
        try? store?.insertOrUpdate(jobs[idx])
        if var run = activeRunsByJobID[id] {
            run.statusNote = note
            if let sessionID {
                run.sessionID = sessionID
            }
            activeRunsByJobID[id] = run
            try? store?.insertOrUpdateRun(run)
        }
        reloadDerivedState(for: id)
    }

    func beginRun(jobID: String, sessionID: String? = nil, startedAt: Date = Date()) -> ScheduledJobRun? {
        guard let jobIndex = jobs.firstIndex(where: { $0.id == jobID }) else { return nil }
        let run = ScheduledJobRun.make(jobID: jobID, sessionID: sessionID, startedAt: startedAt)
        activeRunsByJobID[jobID] = run
        jobs[jobIndex].lastRunStartedAt = startedAt
        jobs[jobIndex].lastRunFinishedAt = nil
        jobs[jobIndex].lastRunFirstIssueAt = nil
        jobs[jobIndex].lastRunOutcome = nil
        jobs[jobIndex].lastRunSummary = nil
        jobs[jobIndex].lastLearnedLessonCount = 0
        if let sessionID {
            jobs[jobIndex].dedicatedSessionID = sessionID
        }
        try? store?.insertOrUpdateRun(run)
        try? store?.insertOrUpdate(jobs[jobIndex])
        reloadDerivedState(for: jobID)
        return run
    }

    func updateActiveRunSession(jobID: String, sessionID: String) {
        guard let jobIndex = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[jobIndex].dedicatedSessionID = sessionID
        if var run = activeRunsByJobID[jobID] {
            run.sessionID = sessionID
            activeRunsByJobID[jobID] = run
            try? store?.insertOrUpdateRun(run)
        }
        try? store?.insertOrUpdate(jobs[jobIndex])
        reloadDerivedState(for: jobID)
    }

    func activeRun(jobID: String) -> ScheduledJobRun? {
        activeRunsByJobID[jobID]
    }

    func completeRun(
        jobID: String,
        outcome: ScheduledJobRunOutcome,
        statusNote: String,
        summaryText: String?,
        firstIssueAt: Date?,
        learnedLessonCount: Int,
        finishedAt: Date = Date()
    ) {
        guard let jobIndex = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        var run = activeRunsByJobID[jobID] ?? ScheduledJobRun.make(jobID: jobID, startedAt: finishedAt)
        run.finishedAt = finishedAt
        run.outcome = outcome
        run.firstIssueAt = firstIssueAt
        run.statusNote = statusNote
        run.summaryText = summaryText
        run.learnedLessonCount = learnedLessonCount
        activeRunsByJobID[jobID] = nil

        jobs[jobIndex].lastRunAt = finishedAt
        jobs[jobIndex].lastRunNote = statusNote
        jobs[jobIndex].lastRunOutcome = outcome
        jobs[jobIndex].lastRunStartedAt = run.startedAt
        jobs[jobIndex].lastRunFinishedAt = finishedAt
        jobs[jobIndex].lastRunFirstIssueAt = firstIssueAt
        jobs[jobIndex].lastRunSummary = summaryText
        jobs[jobIndex].lastLearnedLessonCount = learnedLessonCount
        if let sessionID = run.sessionID {
            jobs[jobIndex].dedicatedSessionID = sessionID
        }

        try? store?.insertOrUpdateRun(run)
        try? store?.insertOrUpdate(jobs[jobIndex])
        reloadDerivedState(for: jobID)
    }

    func runs(for jobID: String, limit: Int = 10) -> [ScheduledJobRun] {
        Array((runsByJobID[jobID] ?? []).prefix(limit))
    }

    func automationLessons(for job: ScheduledJob, cwd: String?) -> [AssistantMemoryEntry] {
        if cwd == nil, let cached = automationLessonsByJobID[job.id] {
            return cached
        }
        let loaded = automationMemoryService.activeLessons(for: job, cwd: cwd)
        if cwd == nil {
            automationLessonsByJobID[job.id] = loaded
        }
        return loaded
    }

    // MARK: - Timer

    /// Schedules the timer to fire exactly when the next future job is due (or 60s fallback).
    private func scheduleNextTimer() {
        timer?.invalidate()
        timer = nil

        let now = Date()
        let nextDue = jobs
            .filter { $0.isEnabled }
            .compactMap { $0.nextRunAt }
            .filter { $0 > now }
            .min()

        let interval = nextDue.map { max(1, $0.timeIntervalSinceNow) } ?? 60
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.refreshSchedule()
            }
        }
    }

    private func fireDueJobs() {
        let now = Date()
        for i in jobs.indices {
            guard jobs[i].isEnabled,
                  let nextRun = jobs[i].nextRunAt,
                  nextRun <= now else { continue }

            jobs[i].lastRunAt = now
            jobs[i].nextRunAt = jobs[i].computeNextRunDate(after: now)
            try? store?.insertOrUpdate(jobs[i])
            enqueue(jobID: jobs[i].id, allowsDisabledExecution: false)
        }
    }

    // MARK: - Global Queue

    private func enqueue(jobID: String, allowsDisabledExecution: Bool) {
        guard activeExecution?.jobID != jobID,
              !pendingExecutionJobIDs.contains(jobID),
              !runningJobIDs.contains(jobID) else { return }
        pendingExecutions.append(
            PendingExecution(jobID: jobID, allowsDisabledExecution: allowsDisabledExecution)
        )
        pendingExecutionJobIDs.insert(jobID)
        startNextQueuedExecutionIfPossible()
    }

    private func startNextQueuedExecutionIfPossible() {
        guard activeExecution == nil else { return }

        while !pendingExecutions.isEmpty {
            let next = pendingExecutions.removeFirst()
            pendingExecutionJobIDs.remove(next.jobID)
            guard let job = jobs.first(where: { $0.id == next.jobID }) else { continue }
            guard next.allowsDisabledExecution || job.isEnabled else { continue }

            activeExecution = next
            runningJobIDs.insert(job.id)

            var userInfo: [String: Any] = [
                "jobID": job.id,
                "prompt": job.prompt,
                "jobName": job.name
            ]
            if let modelID = job.preferredModelID {
                userInfo["preferredModelID"] = modelID
            }
            if let effort = job.reasoningEffort {
                userInfo["reasoningEffort"] = effort.rawValue
            }

            NotificationCenter.default.post(
                name: .openAssistRunScheduledJob,
                object: nil,
                userInfo: userInfo
            )
            return
        }
    }

    private func reloadDerivedState(for jobID: String? = nil) {
        if let store {
            if let jobID {
                runsByJobID[jobID] = (try? store.fetchRuns(jobID: jobID, limit: 10)) ?? []
                if let job = jobs.first(where: { $0.id == jobID }) {
                    automationLessonsByJobID[jobID] = automationMemoryService.activeLessons(for: job, cwd: nil)
                }
            } else {
                for job in jobs {
                    runsByJobID[job.id] = (try? store.fetchRuns(jobID: job.id, limit: 10)) ?? []
                    automationLessonsByJobID[job.id] = automationMemoryService.activeLessons(for: job, cwd: nil)
                }
            }
        }
    }
}
