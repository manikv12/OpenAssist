import Foundation

enum ScheduledJobRunOutcome: String, Codable, CaseIterable {
    case completed
    case failed
    case interrupted

    var displayName: String {
        switch self {
        case .completed:
            return "Succeeded"
        case .failed:
            return "Failed"
        case .interrupted:
            return "Stopped"
        }
    }
}

struct ScheduledJobRun: Identifiable, Codable, Equatable {
    var id: String
    var jobID: String
    var sessionID: String?
    var startedAt: Date
    var finishedAt: Date?
    var outcome: ScheduledJobRunOutcome?
    var firstIssueAt: Date?
    var statusNote: String?
    var summaryText: String?
    var learnedLessonCount: Int

    static func make(jobID: String, sessionID: String? = nil, startedAt: Date = Date()) -> ScheduledJobRun {
        ScheduledJobRun(
            id: UUID().uuidString,
            jobID: jobID,
            sessionID: sessionID,
            startedAt: startedAt,
            finishedAt: nil,
            outcome: nil,
            firstIssueAt: nil,
            statusNote: nil,
            summaryText: nil,
            learnedLessonCount: 0
        )
    }
}

enum ScheduledJobType: String, Codable, CaseIterable {
    case browser
    case app
    case system
    case general

    var displayName: String {
        switch self {
        case .browser: return "Browser"
        case .app: return "App Control"
        case .system: return "System"
        case .general: return "General"
        }
    }

    var iconName: String {
        switch self {
        case .browser: return "safari"
        case .app: return "app.badge"
        case .system: return "gearshape"
        case .general: return "sparkles"
        }
    }
}

enum ScheduledJobRecurrence: String, Codable, CaseIterable {
    case everyNMinutes
    case everyHour
    case daily
    case weekdays
    case weekends
    case weekly

    var displayName: String {
        switch self {
        case .everyNMinutes: return "Every N Minutes"
        case .everyHour: return "Every Hour"
        case .daily: return "Daily"
        case .weekdays: return "Weekdays"
        case .weekends: return "Weekends"
        case .weekly: return "Weekly"
        }
    }

    var usesHourAndMinute: Bool {
        switch self {
        case .daily, .weekdays, .weekends, .weekly: return true
        case .everyHour, .everyNMinutes: return false
        }
    }

    var usesMinuteOnly: Bool { self == .everyHour }
    var usesInterval: Bool { self == .everyNMinutes }
    var usesWeekday: Bool { self == .weekly }
}

struct ScheduledJob: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var prompt: String
    var jobType: ScheduledJobType
    var recurrence: ScheduledJobRecurrence
    var hour: Int           // 0–23
    var minute: Int         // 0–59
    var weekday: Int        // 1=Sunday…7=Saturday (for .weekly)
    var intervalMinutes: Int
    var isEnabled: Bool
    var lastRunAt: Date?
    var nextRunAt: Date?
    var createdAt: Date
    /// Override model for this job. nil = use the assistant's current selection.
    var preferredModelID: String?
    /// Override reasoning effort for this job. nil = use the assistant's current setting.
    var reasoningEffort: AssistantReasoningEffort?
    /// Short human-readable result from the last execution attempt.
    var lastRunNote: String?
    /// The Codex thread ID dedicated to this job. Reused across runs so the assistant retains context.
    var dedicatedSessionID: String?
    /// Latest persisted run status for quick UI display.
    var lastRunOutcome: ScheduledJobRunOutcome?
    var lastRunStartedAt: Date?
    var lastRunFinishedAt: Date?
    var lastRunFirstIssueAt: Date?
    var lastRunSummary: String?
    var lastLearnedLessonCount: Int

    static func make(
        name: String,
        prompt: String,
        jobType: ScheduledJobType = .general,
        recurrence: ScheduledJobRecurrence = .daily,
        hour: Int = 9,
        minute: Int = 0,
        weekday: Int = 2,
        intervalMinutes: Int = 60,
        preferredModelID: String? = nil,
        reasoningEffort: AssistantReasoningEffort? = nil
    ) -> ScheduledJob {
        var job = ScheduledJob(
            id: UUID().uuidString,
            name: name,
            prompt: prompt,
            jobType: jobType,
            recurrence: recurrence,
            hour: hour,
            minute: minute,
            weekday: weekday,
            intervalMinutes: intervalMinutes,
            isEnabled: true,
            lastRunAt: nil,
            nextRunAt: nil,
            createdAt: Date(),
            preferredModelID: preferredModelID,
            reasoningEffort: reasoningEffort,
            lastRunNote: nil,
            dedicatedSessionID: nil,
            lastRunOutcome: nil,
            lastRunStartedAt: nil,
            lastRunFinishedAt: nil,
            lastRunFirstIssueAt: nil,
            lastRunSummary: nil,
            lastLearnedLessonCount: 0
        )
        job.nextRunAt = job.computeNextRunDate(after: Date())
        return job
    }

    func computeNextRunDate(after date: Date) -> Date? {
        let cal = Calendar.current
        switch recurrence {
        case .everyNMinutes:
            return cal.date(byAdding: .minute, value: max(1, intervalMinutes), to: date)
        case .everyHour:
            var c = cal.dateComponents([.year, .month, .day, .hour], from: date)
            c.minute = minute
            c.second = 0
            if let candidate = cal.date(from: c), candidate > date { return candidate }
            c.hour = (c.hour ?? 0) + 1
            return cal.date(from: c)
        case .daily:
            return nextMatchingDate(after: date, validWeekdays: nil, calendar: cal)
        case .weekdays:
            return nextMatchingDate(after: date, validWeekdays: [2, 3, 4, 5, 6], calendar: cal)
        case .weekends:
            return nextMatchingDate(after: date, validWeekdays: [1, 7], calendar: cal)
        case .weekly:
            return nextMatchingDate(after: date, validWeekdays: [weekday], calendar: cal)
        }
    }

    private func nextMatchingDate(after date: Date, validWeekdays: [Int]?, calendar: Calendar) -> Date? {
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: date) else { continue }
            var c = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
            c.hour = hour
            c.minute = minute
            c.second = 0
            guard let candidate = calendar.date(from: c) else { continue }
            if candidate <= date { continue }
            if let valid = validWeekdays, !valid.contains(c.weekday ?? 0) { continue }
            return candidate
        }
        return nil
    }

    var scheduleDescription: String {
        switch recurrence {
        case .everyNMinutes:
            return "Every \(intervalMinutes)m"
        case .everyHour:
            return "Hourly at :\(String(format: "%02d", minute))"
        case .daily:
            return "Daily at \(timeString)"
        case .weekdays:
            return "Weekdays at \(timeString)"
        case .weekends:
            return "Weekends at \(timeString)"
        case .weekly:
            let sym = Calendar.current.weekdaySymbols
            let dayName = sym.indices.contains(weekday - 1) ? sym[weekday - 1] : "Day \(weekday)"
            return "\(dayName)s at \(timeString)"
        }
    }

    private var timeString: String {
        let period = hour >= 12 ? "PM" : "AM"
        let displayHour = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour)
        return "\(displayHour):\(String(format: "%02d", minute)) \(period)"
    }

    var nextRunDescription: String {
        guard let next = nextRunAt else { return "—" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: next, relativeTo: Date())
    }
}
