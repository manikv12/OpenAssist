import AppKit
import EventKit
import Foundation

private let eventStore = EKEventStore()

private enum HelperError: Error, CustomStringConvertible {
    case invalidCommand
    case missingField(String)
    case invalidDate(String)
    case invalidRecurrence(String)
    case accessDenied(String)
    case notFound(String)
    case saveFailed(String)

    var description: String {
        switch self {
        case .invalidCommand:
            return "Apple EventKit command is invalid."
        case .missingField(let field):
            return "Missing required field: \(field)."
        case .invalidDate(let value):
            return "Could not parse date: \(value)."
        case .invalidRecurrence(let value):
            return value
        case .accessDenied(let service):
            return "Open Assist does not have access to Apple \(service). Grant access in Settings."
        case .notFound(let value):
            return value
        case .saveFailed(let value):
            return value
        }
    }
}

// Dates serialize with the LOCAL timezone offset (e.g. 2026-07-20T21:00:00-05:00),
// never bare UTC. With the default UTC formatter, an evening reminder rendered as
// the NEXT day's date ("9 PM today" became tomorrow's date), and models reading
// the payload told the user the wrong day. Local-offset ISO8601 stays parseable
// everywhere while the visible date/time components match the user's clock.
private let isoFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone.current
    return formatter
}()

private let isoFormatterNoFraction: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone.current
    return formatter
}()

/*
 TCC responsibility disclaim.

 When Electron spawns this helper directly, macOS attributes EventKit
 permission checks and prompts to the parent ("responsible") process. The
 stock development Electron binary ships without Reminders/Calendar usage
 strings, so requests are denied instantly and no dialog ever appears; a
 packaged app works, but its grant then belongs to the app identity and
 resets whenever that identity changes. Re-spawning ourselves with
 responsibility disclaimed makes the helper its own TCC subject: the dialog
 appears (attributed to this signed helper bundle, which carries the usage
 strings), and a single grant covers both dev and packaged runs.
 */
private var disclaimedChildPid: pid_t = -1

private func reexecDisclaimedIfNeeded() {
    if ProcessInfo.processInfo.environment["OPENASSIST_EVENTKIT_DISCLAIMED"] == "1" { return }
    typealias SetDisclaimFunction = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>?, Int32) -> Int32
    guard let disclaimSymbol = dlsym(dlopen(nil, RTLD_NOW), "responsibility_spawnattrs_setdisclaim") else { return }
    let setDisclaim = unsafeBitCast(disclaimSymbol, to: SetDisclaimFunction.self)
    let executablePath = Bundle.main.executablePath ?? CommandLine.arguments[0]

    var attributes: posix_spawnattr_t? = nil
    guard posix_spawnattr_init(&attributes) == 0 else { return }
    defer { posix_spawnattr_destroy(&attributes) }
    guard setDisclaim(&attributes, 1) == 0 else { return }

    setenv("OPENASSIST_EVENTKIT_DISCLAIMED", "1", 1)
    var argv: [UnsafeMutablePointer<CChar>?] = CommandLine.arguments.map { strdup($0) }
    argv.append(nil)
    var childPid: pid_t = 0
    let spawnStatus = posix_spawn(&childPid, executablePath, nil, &attributes, argv, environ)
    for argument in argv where argument != nil { free(argument) }
    // If the disclaimed spawn fails for any reason, keep running un-disclaimed
    // so commands still work (with parent-attributed TCC) instead of breaking.
    guard spawnStatus == 0 else { return }

    disclaimedChildPid = childPid
    signal(SIGTERM) { _ in
        if disclaimedChildPid > 0 { kill(disclaimedChildPid, SIGTERM) }
        exit(1)
    }
    signal(SIGINT) { _ in
        if disclaimedChildPid > 0 { kill(disclaimedChildPid, SIGINT) }
        exit(1)
    }

    var status: Int32 = 0
    while waitpid(childPid, &status, 0) == -1 && errno == EINTR {}
    if (status & 0x7f) == 0 {
        exit((status >> 8) & 0xff)
    }
    exit(1)
}

private func emit(_ payload: [String: Any]) -> Never {
    let safePayload: [String: Any]
    if JSONSerialization.isValidJSONObject(payload) {
        safePayload = payload
    } else {
        safePayload = ["ok": false, "error": "Apple EventKit helper produced invalid JSON."]
    }
    let data = (try? JSONSerialization.data(withJSONObject: safePayload, options: [.sortedKeys])) ?? Data()
    if let line = String(data: data, encoding: .utf8) {
        print(line)
    }
    exit(safePayload["ok"] as? Bool == true ? 0 : 1)
}

private func inputJSON() throws -> [String: Any] {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if let jsonIndex = arguments.firstIndex(of: "--json") {
        let valueIndex = arguments.index(after: jsonIndex)
        guard valueIndex < arguments.endIndex else { throw HelperError.invalidCommand }
        guard let data = arguments[valueIndex].data(using: .utf8),
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HelperError.invalidCommand
        }
        return value
    }
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard !data.isEmpty,
          let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw HelperError.invalidCommand
    }
    return value
}

private func stringField(_ input: [String: Any], _ field: String, required: Bool = false) throws -> String? {
    let value = (input[field] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    if required && (value ?? "").isEmpty { throw HelperError.missingField(field) }
    return value?.isEmpty == true ? nil : value
}

private func intField(_ input: [String: Any], _ field: String, fallback: Int) -> Int {
    if let value = input[field] as? Int { return value }
    if let value = input[field] as? Double { return Int(value) }
    if let value = input[field] as? String, let parsed = Int(value) { return parsed }
    return fallback
}

private func boolField(_ input: [String: Any], _ field: String, fallback: Bool = false) -> Bool {
    if let value = input[field] as? Bool { return value }
    if let value = input[field] as? String {
        return ["true", "1", "yes"].contains(value.lowercased())
    }
    return fallback
}

private func parseDate(_ value: String?) throws -> Date? {
    guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
    if let date = isoFormatter.date(from: raw) ?? isoFormatterNoFraction.date(from: raw) {
        return date
    }
    let dateOnly = DateFormatter()
    dateOnly.locale = Locale(identifier: "en_US_POSIX")
    dateOnly.dateFormat = "yyyy-MM-dd"
    if let date = dateOnly.date(from: raw) { return date }
    throw HelperError.invalidDate(raw)
}

private func dateComponents(_ value: String?) throws -> DateComponents? {
    guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
    if raw.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
        let parts = raw.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { throw HelperError.invalidDate(raw) }
        return DateComponents(calendar: Calendar.current, year: parts[0], month: parts[1], day: parts[2])
    }
    guard let date = try parseDate(raw) else { return nil }
    return Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
}

private func isoString(_ date: Date?) -> String? {
    guard let date else { return nil }
    return isoFormatterNoFraction.string(from: date)
}

private func statusLabel(_ status: EKAuthorizationStatus) -> String {
    switch status {
    case .notDetermined:
        return "notDetermined"
    case .restricted:
        return "restricted"
    case .denied:
        return "denied"
    case .authorized:
        return "authorized"
    case .fullAccess:
        return "fullAccess"
    case .writeOnly:
        return "writeOnly"
    @unknown default:
        return "unknown"
    }
}

private func hasReadableAccess(_ type: EKEntityType) -> Bool {
    let status = EKEventStore.authorizationStatus(for: type)
    if #available(macOS 14.0, *) {
        return status == .authorized || status == .fullAccess
    }
    return status == .authorized
}

private func requireAccess(_ type: EKEntityType) throws {
    if hasReadableAccess(type) { return }
    throw HelperError.accessDenied(type == .reminder ? "Reminders" : "Calendar")
}

private final class AccessRequestState: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var granted = false
    private var errorMessage: String?

    func complete(granted: Bool, error: Error?) {
        lock.lock()
        self.granted = granted
        self.errorMessage = error?.localizedDescription
        self.finished = true
        lock.unlock()
    }

    func snapshot() -> (finished: Bool, granted: Bool, errorMessage: String?) {
        lock.lock()
        defer { lock.unlock() }
        return (finished, granted, errorMessage)
    }
}

private func requestAccess(_ type: EKEntityType) -> [String: Any] {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    application.activate(ignoringOtherApps: true)
    let state = AccessRequestState()
    if type == .reminder {
        if #available(macOS 14.0, *) {
            eventStore.requestFullAccessToReminders { value, error in
                state.complete(granted: value, error: error)
            }
        } else {
            eventStore.requestAccess(to: .reminder) { value, error in
                state.complete(granted: value, error: error)
            }
        }
    } else {
        if #available(macOS 14.0, *) {
            eventStore.requestFullAccessToEvents { value, error in
                state.complete(granted: value, error: error)
            }
        } else {
            eventStore.requestAccess(to: .event) { value, error in
                state.complete(granted: value, error: error)
            }
        }
    }

    let deadline = Date().addingTimeInterval(60)
    while !state.snapshot().finished && Date() < deadline {
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    let result = state.snapshot()
    let timedOut = !result.finished
    var payload: [String: Any] = [
        "granted": result.granted,
        "status": statusLabel(EKEventStore.authorizationStatus(for: type)),
        "timedOut": timedOut
    ]
    if let errorMessage = result.errorMessage { payload["error"] = errorMessage }
    if timedOut { payload["error"] = "macOS did not finish the permission request." }
    return payload
}

private func calendarName(_ calendar: EKCalendar?) -> String {
    calendar?.title ?? "Default"
}

private func calendar(forName name: String?, type: EKEntityType) -> EKCalendar? {
    let calendars = eventStore.calendars(for: type)
    guard let name, !name.isEmpty else {
        return type == .reminder ? eventStore.defaultCalendarForNewReminders() : eventStore.defaultCalendarForNewEvents
    }
    return calendars.first { $0.title.caseInsensitiveCompare(name) == .orderedSame }
        ?? calendars.first { $0.title.localizedCaseInsensitiveContains(name) }
        ?? (type == .reminder ? eventStore.defaultCalendarForNewReminders() : eventStore.defaultCalendarForNewEvents)
}

private func frequencyLabel(_ frequency: EKRecurrenceFrequency) -> String {
    switch frequency {
    case .daily: return "daily"
    case .weekly: return "weekly"
    case .monthly: return "monthly"
    case .yearly: return "yearly"
    @unknown default: return "unknown"
    }
}

private func recurrenceFrequency(_ raw: String) throws -> EKRecurrenceFrequency {
    switch raw.lowercased() {
    case "daily": return .daily
    case "weekly": return .weekly
    case "monthly": return .monthly
    case "yearly", "annually": return .yearly
    default: throw HelperError.invalidRecurrence("Unsupported recurrence frequency: \(raw). Use daily, weekly, monthly, or yearly.")
    }
}

// Builds a rule from input["recurrence"]. `fallback` (the reminder's existing first
// rule) supplies frequency/interval/end when omitted, so an update with only
// {recurrence: {endDate}} extends the existing series instead of failing.
private func recurrenceRule(from input: [String: Any], fallback: EKRecurrenceRule? = nil) throws -> EKRecurrenceRule? {
    guard let spec = input["recurrence"] as? [String: Any] else { return nil }
    let frequencyRaw = try stringField(spec, "frequency")
    let frequency: EKRecurrenceFrequency
    if let frequencyRaw {
        frequency = try recurrenceFrequency(frequencyRaw)
    } else if let fallback {
        frequency = fallback.frequency
    } else {
        throw HelperError.missingField("recurrence.frequency")
    }
    let interval = max(1, intField(spec, "interval", fallback: fallback.map { $0.interval } ?? 1))
    var end: EKRecurrenceEnd?
    if let endDate = try parseDate(stringField(spec, "endDate")) {
        end = EKRecurrenceEnd(end: endDate)
    } else if intField(spec, "occurrenceCount", fallback: 0) > 0 {
        end = EKRecurrenceEnd(occurrenceCount: intField(spec, "occurrenceCount", fallback: 0))
    } else if let fallbackEnd = fallback?.recurrenceEnd, frequencyRaw == nil {
        // Only interval/nothing changed: keep the existing end.
        end = fallbackEnd
    }
    return EKRecurrenceRule(recurrenceWith: frequency, interval: interval, end: end)
}

private func reminderPayload(_ reminder: EKReminder) -> [String: Any] {
    var payload: [String: Any] = [
        "id": reminder.calendarItemIdentifier,
        "title": reminder.title ?? "Untitled reminder",
        "completed": reminder.isCompleted,
        "calendar": calendarName(reminder.calendar)
    ]
    if let notes = reminder.notes, !notes.isEmpty { payload["notes"] = notes }
    if let dueDateComponents = reminder.dueDateComponents,
       let dueDate = Calendar.current.date(from: dueDateComponents) {
        payload["dueDate"] = isoString(dueDate)
    }
    if let completionDate = reminder.completionDate { payload["completionDate"] = isoString(completionDate) }
    if let rule = reminder.recurrenceRules?.first {
        var recurrence: [String: Any] = [
            "frequency": frequencyLabel(rule.frequency),
            "interval": rule.interval
        ]
        if let end = rule.recurrenceEnd {
            if let endDate = end.endDate { recurrence["endDate"] = isoString(endDate) ?? "" }
            if end.occurrenceCount > 0 { recurrence["occurrenceCount"] = end.occurrenceCount }
        }
        payload["recurrence"] = recurrence
    }
    return payload
}

private func eventPayload(_ event: EKEvent) -> [String: Any] {
    var payload: [String: Any] = [
        "id": event.calendarItemIdentifier,
        "title": event.title ?? "Untitled event",
        "calendar": calendarName(event.calendar),
        "startDate": isoString(event.startDate) ?? "",
        "endDate": isoString(event.endDate) ?? "",
        "isAllDay": event.isAllDay
    ]
    if let notes = event.notes, !notes.isEmpty { payload["notes"] = notes }
    if let location = event.location, !location.isEmpty { payload["location"] = location }
    return payload
}

private func fetchReminders(matching predicate: NSPredicate) -> [EKReminder] {
    let semaphore = DispatchSemaphore(value: 0)
    var reminders: [EKReminder] = []
    eventStore.fetchReminders(matching: predicate) { values in
        reminders = values ?? []
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 20)
    return reminders
}

private func listReminders(_ input: [String: Any]) throws -> [String: Any] {
    try requireAccess(.reminder)
    let calendarFilter = try stringField(input, "calendar")
    let calendars = calendarFilter.flatMap { calendar(forName: $0, type: .reminder).map { [$0] } }
    let dueBefore = try parseDate(stringField(input, "dueBefore") ?? stringField(input, "endDate"))
    let dueAfter = try parseDate(stringField(input, "dueAfter") ?? stringField(input, "startDate"))
    let includeCompleted = boolField(input, "includeCompleted")
    let limit = max(1, min(intField(input, "limit", fallback: 25), 100))
    let predicate = includeCompleted
        ? eventStore.predicateForReminders(in: calendars)
        : eventStore.predicateForIncompleteReminders(withDueDateStarting: dueAfter, ending: dueBefore, calendars: calendars)
    // predicateForReminders(in:) has no date parameters, so the requested due
    // window must be applied here — otherwise "today, including completed"
    // returns every reminder ever created (oldest first) and today's items
    // never survive the limit.
    let reminders = fetchReminders(matching: predicate)
        .filter { reminder in
            guard dueAfter != nil || dueBefore != nil else { return true }
            guard let due = reminder.dueDateComponents.flatMap({ Calendar.current.date(from: $0) }) else { return false }
            if let after = dueAfter, due < after { return false }
            if let before = dueBefore, due > before { return false }
            return true
        }
        .sorted { left, right in
            let leftDate = left.dueDateComponents.flatMap { Calendar.current.date(from: $0) } ?? Date.distantFuture
            let rightDate = right.dueDateComponents.flatMap { Calendar.current.date(from: $0) } ?? Date.distantFuture
            return leftDate < rightDate
        }
        .prefix(limit)
        .map(reminderPayload)
    return ["reminders": Array(reminders)]
}

private func addReminder(_ input: [String: Any]) throws -> [String: Any] {
    try requireAccess(.reminder)
    let title = try stringField(input, "title", required: true)!
    let reminder = EKReminder(eventStore: eventStore)
    reminder.title = title
    reminder.notes = try stringField(input, "notes") ?? stringField(input, "details")
    reminder.calendar = calendar(forName: try stringField(input, "calendar") ?? stringField(input, "list"), type: .reminder)
    if let due = try dateComponents(stringField(input, "dueDate") ?? stringField(input, "due")) {
        reminder.dueDateComponents = due
    }
    if let rule = try recurrenceRule(from: input) {
        guard reminder.dueDateComponents != nil else {
            throw HelperError.missingField("dueDate (required for a recurring reminder)")
        }
        reminder.addRecurrenceRule(rule)
    }
    do {
        try eventStore.save(reminder, commit: true)
        return ["reminder": reminderPayload(reminder)]
    } catch {
        throw HelperError.saveFailed(error.localizedDescription)
    }
}

private func updateReminder(_ input: [String: Any]) throws -> [String: Any] {
    try requireAccess(.reminder)
    let id = try stringField(input, "id", required: true)!
    guard let reminder = eventStore.calendarItem(withIdentifier: id) as? EKReminder else {
        throw HelperError.notFound("Apple Reminder was not found.")
    }

    let title = try stringField(input, "title")
    let notesProvided = input.keys.contains("notes") || input.keys.contains("details") || boolField(input, "clearNotes")
    let dueDateProvided = input.keys.contains("dueDate") || input.keys.contains("due") || boolField(input, "clearDueDate")
    let recurrenceProvided = input["recurrence"] is [String: Any]
    let clearRecurrence = boolField(input, "clearRecurrence")
    if title == nil && !notesProvided && !dueDateProvided && !recurrenceProvided && !clearRecurrence {
        throw HelperError.missingField("title, notes, dueDate, or recurrence")
    }

    if let title { reminder.title = title }
    if notesProvided {
        reminder.notes = boolField(input, "clearNotes")
            ? nil
            : (try stringField(input, "notes") ?? stringField(input, "details"))
    }
    if dueDateProvided {
        reminder.dueDateComponents = boolField(input, "clearDueDate")
            ? nil
            : try dateComponents(stringField(input, "dueDate") ?? stringField(input, "due"))
    }
    if clearRecurrence {
        (reminder.recurrenceRules ?? []).forEach { reminder.removeRecurrenceRule($0) }
    } else if recurrenceProvided {
        // Replace semantics: EKRecurrenceRule is rebuilt (with the existing first
        // rule as fallback for omitted fields) rather than mutated in place.
        let existing = reminder.recurrenceRules?.first
        if let rule = try recurrenceRule(from: input, fallback: existing) {
            guard reminder.dueDateComponents != nil else {
                throw HelperError.missingField("dueDate (required for a recurring reminder)")
            }
            (reminder.recurrenceRules ?? []).forEach { reminder.removeRecurrenceRule($0) }
            reminder.addRecurrenceRule(rule)
        }
    }

    do {
        try eventStore.save(reminder, commit: true)
        return ["reminder": reminderPayload(reminder)]
    } catch {
        throw HelperError.saveFailed(error.localizedDescription)
    }
}

private func completeReminder(_ input: [String: Any]) throws -> [String: Any] {
    try requireAccess(.reminder)
    let id = try stringField(input, "id", required: true)!
    guard let reminder = eventStore.calendarItem(withIdentifier: id) as? EKReminder else {
        throw HelperError.notFound("Apple Reminder was not found.")
    }
    reminder.isCompleted = boolField(input, "completed", fallback: true)
    if reminder.isCompleted {
        reminder.completionDate = Date()
    } else {
        reminder.completionDate = nil
    }
    do {
        try eventStore.save(reminder, commit: true)
        return ["reminder": reminderPayload(reminder)]
    } catch {
        throw HelperError.saveFailed(error.localizedDescription)
    }
}

private func searchReminders(_ input: [String: Any]) throws -> [String: Any] {
    try requireAccess(.reminder)
    let query = try stringField(input, "query", required: true)!
    let terms = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
    let calendarFilter = try stringField(input, "calendar")
    // Match ALL lists with the requested name: list names can repeat (two "Costco"
    // lists), and calendar(forName:) would silently search only the first one.
    let calendars: [EKCalendar]? = calendarFilter.flatMap { name in
        let all = eventStore.calendars(for: .reminder)
        let exact = all.filter { $0.title.caseInsensitiveCompare(name) == .orderedSame }
        let matched = exact.isEmpty ? all.filter { $0.title.localizedCaseInsensitiveContains(name) } : exact
        return matched.isEmpty ? nil : matched
    }
    let includeCompleted = boolField(input, "includeCompleted", fallback: true)
    let completedOnly = boolField(input, "completedOnly")
    let limit = max(1, min(intField(input, "limit", fallback: 25), 100))

    // Title filter runs over the FULL store before any limit, so matches can never
    // be pushed out by unrelated reminders the way the sorted list-reminders cap can.
    let matches = fetchReminders(matching: eventStore.predicateForReminders(in: calendars))
        .filter { reminder in
            let title = (reminder.title ?? "").lowercased()
            guard terms.allSatisfy({ title.contains($0) }) else { return false }
            if completedOnly { return reminder.isCompleted }
            if !includeCompleted { return !reminder.isCompleted }
            return true
        }
    let completedCount = matches.filter { $0.isCompleted }.count
    let sorted = matches.sorted { left, right in
        if left.isCompleted != right.isCompleted { return !left.isCompleted }
        let leftDate = left.completionDate ?? left.dueDateComponents.flatMap { Calendar.current.date(from: $0) } ?? Date.distantPast
        let rightDate = right.completionDate ?? right.dueDateComponents.flatMap { Calendar.current.date(from: $0) } ?? Date.distantPast
        return leftDate > rightDate
    }
    return [
        "reminders": Array(sorted.prefix(limit).map(reminderPayload)),
        "totalMatches": matches.count,
        "completedMatches": completedCount,
        "incompleteMatches": matches.count - completedCount
    ]
}

private func deleteReminder(_ input: [String: Any]) throws -> [String: Any] {
    try requireAccess(.reminder)
    let id = try stringField(input, "id", required: true)!
    guard let reminder = eventStore.calendarItem(withIdentifier: id) as? EKReminder else {
        throw HelperError.notFound("Apple Reminder was not found.")
    }
    do {
        try eventStore.remove(reminder, commit: true)
        return ["deleted": true, "id": id]
    } catch {
        throw HelperError.saveFailed(error.localizedDescription)
    }
}

private func listEvents(_ input: [String: Any]) throws -> [String: Any] {
    try requireAccess(.event)
    let calendarFilter = try stringField(input, "calendar")
    let calendars = calendarFilter.flatMap { calendar(forName: $0, type: .event).map { [$0] } }
    let start = try parseDate(stringField(input, "startDate") ?? stringField(input, "start")) ?? Date()
    let fallbackEnd = Calendar.current.date(byAdding: .day, value: 7, to: start) ?? Date(timeIntervalSinceNow: 7 * 24 * 60 * 60)
    let end = try parseDate(stringField(input, "endDate") ?? stringField(input, "end")) ?? fallbackEnd
    let limit = max(1, min(intField(input, "limit", fallback: 25), 100))
    let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: calendars)
    let events = eventStore.events(matching: predicate)
        .sorted { $0.startDate < $1.startDate }
        .prefix(limit)
        .map(eventPayload)
    return ["events": Array(events)]
}

private func addEvent(_ input: [String: Any]) throws -> [String: Any] {
    try requireAccess(.event)
    let title = try stringField(input, "title", required: true)!
    let start = try parseDate(stringField(input, "startDate") ?? stringField(input, "start"))
    guard let start else { throw HelperError.missingField("startDate") }
    let end = try parseDate(stringField(input, "endDate") ?? stringField(input, "end"))
        ?? Calendar.current.date(byAdding: .hour, value: 1, to: start)
        ?? start.addingTimeInterval(3600)
    let event = EKEvent(eventStore: eventStore)
    event.title = title
    event.startDate = start
    event.endDate = end
    event.isAllDay = boolField(input, "isAllDay")
    event.notes = try stringField(input, "notes") ?? stringField(input, "details")
    event.location = try stringField(input, "location")
    event.calendar = calendar(forName: try stringField(input, "calendar"), type: .event)
    do {
        try eventStore.save(event, span: .thisEvent, commit: true)
        return ["event": eventPayload(event)]
    } catch {
        throw HelperError.saveFailed(error.localizedDescription)
    }
}

reexecDisclaimedIfNeeded()

do {
    let input = try inputJSON()
    let command = try stringField(input, "command", required: true)!
    let data: [String: Any]
    switch command {
    case "status":
        data = [
            "reminders": statusLabel(EKEventStore.authorizationStatus(for: .reminder)),
            "calendar": statusLabel(EKEventStore.authorizationStatus(for: .event))
        ]
    case "request-access":
        let service = try stringField(input, "service", required: true)!
        data = requestAccess(service.lowercased().contains("calendar") || service.lowercased().contains("event") ? .event : .reminder)
    case "list-reminders":
        data = try listReminders(input)
    case "search-reminders":
        data = try searchReminders(input)
    case "add-reminder":
        data = try addReminder(input)
    case "update-reminder":
        data = try updateReminder(input)
    case "complete-reminder":
        data = try completeReminder(input)
    case "delete-reminder":
        data = try deleteReminder(input)
    case "list-events":
        data = try listEvents(input)
    case "add-event":
        data = try addEvent(input)
    default:
        throw HelperError.invalidCommand
    }
    emit(["ok": true, "data": data])
} catch {
    emit(["ok": false, "error": String(describing: error)])
}
