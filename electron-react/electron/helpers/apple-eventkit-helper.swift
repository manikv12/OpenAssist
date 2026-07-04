import EventKit
import Foundation

private let eventStore = EKEventStore()

private enum HelperError: Error, CustomStringConvertible {
    case invalidCommand
    case missingField(String)
    case invalidDate(String)
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
        case .accessDenied(let service):
            return "Open Assist does not have access to Apple \(service). Grant access in Settings."
        case .notFound(let value):
            return value
        case .saveFailed(let value):
            return value
        }
    }
}

private let isoFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

private let isoFormatterNoFraction: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
}()

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
    if status == .authorized || status == .fullAccess { return true }
    return false
}

private func requireAccess(_ type: EKEntityType) throws {
    if hasReadableAccess(type) { return }
    throw HelperError.accessDenied(type == .reminder ? "Reminders" : "Calendar")
}

private func requestAccess(_ type: EKEntityType) -> [String: Any] {
    let semaphore = DispatchSemaphore(value: 0)
    var granted = false
    var errorMessage: String?
    if type == .reminder {
        if #available(macOS 14.0, *) {
            eventStore.requestFullAccessToReminders { value, error in
                granted = value
                errorMessage = error?.localizedDescription
                semaphore.signal()
            }
        } else {
            eventStore.requestAccess(to: .reminder) { value, error in
                granted = value
                errorMessage = error?.localizedDescription
                semaphore.signal()
            }
        }
    } else {
        if #available(macOS 14.0, *) {
            eventStore.requestFullAccessToEvents { value, error in
                granted = value
                errorMessage = error?.localizedDescription
                semaphore.signal()
            }
        } else {
            eventStore.requestAccess(to: .event) { value, error in
                granted = value
                errorMessage = error?.localizedDescription
                semaphore.signal()
            }
        }
    }
    _ = semaphore.wait(timeout: .now() + 60)
    var payload: [String: Any] = [
        "granted": granted,
        "status": statusLabel(EKEventStore.authorizationStatus(for: type))
    ]
    if let errorMessage { payload["error"] = errorMessage }
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
    let reminders = fetchReminders(matching: predicate)
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
    case "add-reminder":
        data = try addReminder(input)
    case "complete-reminder":
        data = try completeReminder(input)
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
