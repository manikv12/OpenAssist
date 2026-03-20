import Foundation
import SQLite3

enum ScheduledJobStoreError: Error {
    case failedToOpenDatabase(path: String, code: Int32, message: String)
    case failedToPrepareStatement(sql: String, code: Int32, message: String)
    case failedToExecuteStatement(sql: String, code: Int32, message: String)
    case invalidDatabaseState
}

final class ScheduledJobStore {
    private var database: OpaquePointer?
    private let lock = NSLock()
    private let databaseURL: URL

    private let transient = unsafeBitCast(Int(-1), to: sqlite3_destructor_type.self)

    static func defaultDatabaseURL() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("OpenAssist", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("scheduled_jobs.sqlite")
    }

    init(databaseURL: URL? = nil) throws {
        self.databaseURL = try databaseURL ?? Self.defaultDatabaseURL()
        try open()
        try ensureSchema()
    }

    deinit {
        sqlite3_close(database)
    }

    // MARK: - Schema

    private func open() throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let code = sqlite3_open_v2(databaseURL.path, &db, flags, nil)
        guard code == SQLITE_OK, let db else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(db)
            throw ScheduledJobStoreError.failedToOpenDatabase(path: databaseURL.path, code: code, message: msg)
        }
        database = db
    }

    private func ensureSchema() throws {
        try execute(sql: "PRAGMA journal_mode=WAL;")
        try execute(sql: """
        CREATE TABLE IF NOT EXISTS scheduled_jobs (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            prompt TEXT NOT NULL,
            job_type TEXT NOT NULL DEFAULT 'general',
            recurrence TEXT NOT NULL DEFAULT 'daily',
            hour INTEGER NOT NULL DEFAULT 9,
            minute INTEGER NOT NULL DEFAULT 0,
            weekday INTEGER NOT NULL DEFAULT 2,
            interval_minutes INTEGER NOT NULL DEFAULT 60,
            is_enabled INTEGER NOT NULL DEFAULT 1,
            last_run_at REAL,
            next_run_at REAL,
            created_at REAL NOT NULL,
            preferred_model_id TEXT,
            reasoning_effort TEXT,
            last_run_note TEXT,
            dedicated_session_id TEXT,
            last_run_outcome TEXT,
            last_run_started_at REAL,
            last_run_finished_at REAL,
            last_run_first_issue_at REAL,
            last_run_summary TEXT,
            last_learned_lesson_count INTEGER NOT NULL DEFAULT 0
        );
        """)
        try execute(sql: """
        CREATE TABLE IF NOT EXISTS scheduled_job_runs (
            id TEXT PRIMARY KEY,
            job_id TEXT NOT NULL,
            session_id TEXT,
            started_at REAL NOT NULL,
            finished_at REAL,
            outcome TEXT,
            first_issue_at REAL,
            status_note TEXT,
            summary_text TEXT,
            learned_lesson_count INTEGER NOT NULL DEFAULT 0,
            FOREIGN KEY(job_id) REFERENCES scheduled_jobs(id) ON DELETE CASCADE
        );
        """)
        // Migrations for databases created before newer columns were added.
        try? execute(sql: "ALTER TABLE scheduled_jobs ADD COLUMN preferred_model_id TEXT;")
        try? execute(sql: "ALTER TABLE scheduled_jobs ADD COLUMN reasoning_effort TEXT;")
        try? execute(sql: "ALTER TABLE scheduled_jobs ADD COLUMN last_run_note TEXT;")
        try? execute(sql: "ALTER TABLE scheduled_jobs ADD COLUMN dedicated_session_id TEXT;")
        try? execute(sql: "ALTER TABLE scheduled_jobs ADD COLUMN last_run_outcome TEXT;")
        try? execute(sql: "ALTER TABLE scheduled_jobs ADD COLUMN last_run_started_at REAL;")
        try? execute(sql: "ALTER TABLE scheduled_jobs ADD COLUMN last_run_finished_at REAL;")
        try? execute(sql: "ALTER TABLE scheduled_jobs ADD COLUMN last_run_first_issue_at REAL;")
        try? execute(sql: "ALTER TABLE scheduled_jobs ADD COLUMN last_run_summary TEXT;")
        try? execute(sql: "ALTER TABLE scheduled_jobs ADD COLUMN last_learned_lesson_count INTEGER NOT NULL DEFAULT 0;")
    }

    // MARK: - CRUD

    func insertOrUpdate(_ job: ScheduledJob) throws {
        let sql = """
        INSERT INTO scheduled_jobs
            (id, name, prompt, job_type, recurrence, hour, minute, weekday,
             interval_minutes, is_enabled, last_run_at, next_run_at, created_at,
             preferred_model_id, reasoning_effort, last_run_note, dedicated_session_id,
             last_run_outcome, last_run_started_at, last_run_finished_at, last_run_first_issue_at,
             last_run_summary, last_learned_lesson_count)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            name = excluded.name,
            prompt = excluded.prompt,
            job_type = excluded.job_type,
            recurrence = excluded.recurrence,
            hour = excluded.hour,
            minute = excluded.minute,
            weekday = excluded.weekday,
            interval_minutes = excluded.interval_minutes,
            is_enabled = excluded.is_enabled,
            last_run_at = excluded.last_run_at,
            next_run_at = excluded.next_run_at,
            preferred_model_id = excluded.preferred_model_id,
            reasoning_effort = excluded.reasoning_effort,
            last_run_note = excluded.last_run_note,
            dedicated_session_id = excluded.dedicated_session_id,
            last_run_outcome = excluded.last_run_outcome,
            last_run_started_at = excluded.last_run_started_at,
            last_run_finished_at = excluded.last_run_finished_at,
            last_run_first_issue_at = excluded.last_run_first_issue_at,
            last_run_summary = excluded.last_run_summary,
            last_learned_lesson_count = excluded.last_learned_lesson_count;
        """
        try execute(sql: sql) { stmt in
            self.bind(job.id, at: 1, in: stmt)
            self.bind(job.name, at: 2, in: stmt)
            self.bind(job.prompt, at: 3, in: stmt)
            self.bind(job.jobType.rawValue, at: 4, in: stmt)
            self.bind(job.recurrence.rawValue, at: 5, in: stmt)
            self.bind(Int64(job.hour), at: 6, in: stmt)
            self.bind(Int64(job.minute), at: 7, in: stmt)
            self.bind(Int64(job.weekday), at: 8, in: stmt)
            self.bind(Int64(job.intervalMinutes), at: 9, in: stmt)
            self.bind(Int64(job.isEnabled ? 1 : 0), at: 10, in: stmt)
            self.bindOptionalDouble(job.lastRunAt?.timeIntervalSince1970, at: 11, in: stmt)
            self.bindOptionalDouble(job.nextRunAt?.timeIntervalSince1970, at: 12, in: stmt)
            self.bind(job.createdAt.timeIntervalSince1970, at: 13, in: stmt)
            self.bindOptionalString(job.preferredModelID, at: 14, in: stmt)
            self.bindOptionalString(job.reasoningEffort?.rawValue, at: 15, in: stmt)
            self.bindOptionalString(job.lastRunNote, at: 16, in: stmt)
            self.bindOptionalString(job.dedicatedSessionID, at: 17, in: stmt)
            self.bindOptionalString(job.lastRunOutcome?.rawValue, at: 18, in: stmt)
            self.bindOptionalDouble(job.lastRunStartedAt?.timeIntervalSince1970, at: 19, in: stmt)
            self.bindOptionalDouble(job.lastRunFinishedAt?.timeIntervalSince1970, at: 20, in: stmt)
            self.bindOptionalDouble(job.lastRunFirstIssueAt?.timeIntervalSince1970, at: 21, in: stmt)
            self.bindOptionalString(job.lastRunSummary, at: 22, in: stmt)
            self.bind(Int64(job.lastLearnedLessonCount), at: 23, in: stmt)
        }
    }

    func insertOrUpdateRun(_ run: ScheduledJobRun) throws {
        let sql = """
        INSERT INTO scheduled_job_runs
            (id, job_id, session_id, started_at, finished_at, outcome, first_issue_at,
             status_note, summary_text, learned_lesson_count)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            job_id = excluded.job_id,
            session_id = excluded.session_id,
            started_at = excluded.started_at,
            finished_at = excluded.finished_at,
            outcome = excluded.outcome,
            first_issue_at = excluded.first_issue_at,
            status_note = excluded.status_note,
            summary_text = excluded.summary_text,
            learned_lesson_count = excluded.learned_lesson_count;
        """
        try execute(sql: sql) { stmt in
            self.bind(run.id, at: 1, in: stmt)
            self.bind(run.jobID, at: 2, in: stmt)
            self.bindOptionalString(run.sessionID, at: 3, in: stmt)
            self.bind(run.startedAt.timeIntervalSince1970, at: 4, in: stmt)
            self.bindOptionalDouble(run.finishedAt?.timeIntervalSince1970, at: 5, in: stmt)
            self.bindOptionalString(run.outcome?.rawValue, at: 6, in: stmt)
            self.bindOptionalDouble(run.firstIssueAt?.timeIntervalSince1970, at: 7, in: stmt)
            self.bindOptionalString(run.statusNote, at: 8, in: stmt)
            self.bindOptionalString(run.summaryText, at: 9, in: stmt)
            self.bind(Int64(run.learnedLessonCount), at: 10, in: stmt)
        }
    }

    func fetchRuns(jobID: String, limit: Int = 20) throws -> [ScheduledJobRun] {
        let normalizedLimit = max(1, min(limit, 200))
        let sql = """
        SELECT id, job_id, session_id, started_at, finished_at, outcome, first_issue_at,
               status_note, summary_text, learned_lesson_count
        FROM scheduled_job_runs
        WHERE job_id = ?
        ORDER BY started_at DESC
        LIMIT ?;
        """
        return try query(sql: sql, bind: { stmt in
            self.bind(jobID, at: 1, in: stmt)
            self.bind(Int64(normalizedLimit), at: 2, in: stmt)
        }, mapRow: { stmt in
            ScheduledJobRun(
                id: self.readString(at: 0, in: stmt) ?? UUID().uuidString,
                jobID: self.readString(at: 1, in: stmt) ?? jobID,
                sessionID: self.readString(at: 2, in: stmt),
                startedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
                finishedAt: sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)),
                outcome: self.readString(at: 5, in: stmt).flatMap { ScheduledJobRunOutcome(rawValue: $0) },
                firstIssueAt: sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6)),
                statusNote: self.readString(at: 7, in: stmt),
                summaryText: self.readString(at: 8, in: stmt),
                learnedLessonCount: Int(sqlite3_column_int64(stmt, 9))
            )
        })
    }

    func delete(id: String) throws {
        try execute(sql: "DELETE FROM scheduled_job_runs WHERE job_id = ?;") { stmt in
            self.bind(id, at: 1, in: stmt)
        }
        try execute(sql: "DELETE FROM scheduled_jobs WHERE id = ?;") { stmt in
            self.bind(id, at: 1, in: stmt)
        }
    }

    func fetchAll() throws -> [ScheduledJob] {
        let sql = """
        SELECT id, name, prompt, job_type, recurrence, hour, minute, weekday,
               interval_minutes, is_enabled, last_run_at, next_run_at, created_at,
               preferred_model_id, reasoning_effort, last_run_note, dedicated_session_id,
               last_run_outcome, last_run_started_at, last_run_finished_at, last_run_first_issue_at,
               last_run_summary, last_learned_lesson_count
        FROM scheduled_jobs ORDER BY created_at ASC;
        """
        return try query(sql: sql) { stmt in
            let lastRunRaw = sqlite3_column_type(stmt, 10) == SQLITE_NULL
                ? nil : sqlite3_column_double(stmt, 10)
            let nextRunRaw = sqlite3_column_type(stmt, 11) == SQLITE_NULL
                ? nil : sqlite3_column_double(stmt, 11)
            let lastRunStartedRaw = sqlite3_column_type(stmt, 18) == SQLITE_NULL
                ? nil : sqlite3_column_double(stmt, 18)
            let lastRunFinishedRaw = sqlite3_column_type(stmt, 19) == SQLITE_NULL
                ? nil : sqlite3_column_double(stmt, 19)
            let lastRunFirstIssueRaw = sqlite3_column_type(stmt, 20) == SQLITE_NULL
                ? nil : sqlite3_column_double(stmt, 20)
            return ScheduledJob(
                id: self.readString(at: 0, in: stmt) ?? UUID().uuidString,
                name: self.readString(at: 1, in: stmt) ?? "",
                prompt: self.readString(at: 2, in: stmt) ?? "",
                jobType: ScheduledJobType(rawValue: self.readString(at: 3, in: stmt) ?? "") ?? .general,
                recurrence: ScheduledJobRecurrence(rawValue: self.readString(at: 4, in: stmt) ?? "") ?? .daily,
                hour: Int(sqlite3_column_int64(stmt, 5)),
                minute: Int(sqlite3_column_int64(stmt, 6)),
                weekday: Int(sqlite3_column_int64(stmt, 7)),
                intervalMinutes: Int(sqlite3_column_int64(stmt, 8)),
                isEnabled: sqlite3_column_int64(stmt, 9) == 1,
                lastRunAt: lastRunRaw.map { Date(timeIntervalSince1970: $0) },
                nextRunAt: nextRunRaw.map { Date(timeIntervalSince1970: $0) },
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 12)),
                preferredModelID: self.readString(at: 13, in: stmt),
                reasoningEffort: self.readString(at: 14, in: stmt).flatMap { AssistantReasoningEffort(rawValue: $0) },
                lastRunNote: self.readString(at: 15, in: stmt),
                dedicatedSessionID: self.readString(at: 16, in: stmt),
                lastRunOutcome: self.readString(at: 17, in: stmt).flatMap { ScheduledJobRunOutcome(rawValue: $0) },
                lastRunStartedAt: lastRunStartedRaw.map { Date(timeIntervalSince1970: $0) },
                lastRunFinishedAt: lastRunFinishedRaw.map { Date(timeIntervalSince1970: $0) },
                lastRunFirstIssueAt: lastRunFirstIssueRaw.map { Date(timeIntervalSince1970: $0) },
                lastRunSummary: self.readString(at: 21, in: stmt),
                lastLearnedLessonCount: Int(sqlite3_column_int64(stmt, 22))
            )
        }
    }

    // MARK: - Core Helpers

    private func withDatabase<T>(_ block: (OpaquePointer) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard let db = database else { throw ScheduledJobStoreError.invalidDatabaseState }
        return try block(db)
    }

    private func execute(sql: String, bind binder: ((OpaquePointer) throws -> Void)? = nil) throws {
        try withDatabase { db in
            var stmt: OpaquePointer?
            let code = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            guard code == SQLITE_OK, let stmt else {
                let msg = String(cString: sqlite3_errmsg(db))
                throw ScheduledJobStoreError.failedToPrepareStatement(sql: sql, code: code, message: msg)
            }
            defer { sqlite3_finalize(stmt) }
            try binder?(stmt)
            var step = sqlite3_step(stmt)
            while step == SQLITE_ROW { step = sqlite3_step(stmt) }
            guard step == SQLITE_DONE else {
                let msg = String(cString: sqlite3_errmsg(db))
                throw ScheduledJobStoreError.failedToExecuteStatement(sql: sql, code: step, message: msg)
            }
        }
    }

    private func query<T>(
        sql: String,
        bind binder: ((OpaquePointer) throws -> Void)? = nil,
        mapRow: (OpaquePointer) throws -> T
    ) throws -> [T] {
        try withDatabase { db in
            var stmt: OpaquePointer?
            let code = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            guard code == SQLITE_OK, let stmt else {
                let msg = String(cString: sqlite3_errmsg(db))
                throw ScheduledJobStoreError.failedToPrepareStatement(sql: sql, code: code, message: msg)
            }
            defer { sqlite3_finalize(stmt) }
            try binder?(stmt)
            var rows: [T] = []
            while true {
                let step = sqlite3_step(stmt)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW else {
                    let msg = String(cString: sqlite3_errmsg(db))
                    throw ScheduledJobStoreError.failedToExecuteStatement(sql: sql, code: step, message: msg)
                }
                rows.append(try mapRow(stmt))
            }
            return rows
        }
    }

    // MARK: - Bind Helpers

    private func bind(_ value: String, at index: Int32, in stmt: OpaquePointer) {
        sqlite3_bind_text(stmt, index, value, -1, transient)
    }

    private func bind(_ value: Int64, at index: Int32, in stmt: OpaquePointer) {
        sqlite3_bind_int64(stmt, index, value)
    }

    private func bind(_ value: Double, at index: Int32, in stmt: OpaquePointer) {
        sqlite3_bind_double(stmt, index, value)
    }

    private func bindOptionalDouble(_ value: Double?, at index: Int32, in stmt: OpaquePointer) {
        if let value { sqlite3_bind_double(stmt, index, value) }
        else { sqlite3_bind_null(stmt, index) }
    }

    private func bindOptionalString(_ value: String?, at index: Int32, in stmt: OpaquePointer) {
        if let value { sqlite3_bind_text(stmt, index, value, -1, transient) }
        else { sqlite3_bind_null(stmt, index) }
    }

    private func readString(at index: Int32, in stmt: OpaquePointer) -> String? {
        guard let ptr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: ptr)
    }
}
