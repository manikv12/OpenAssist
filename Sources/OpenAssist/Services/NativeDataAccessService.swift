import Contacts
import EventKit
import Foundation
import SQLite3

/// Provides direct native framework access to macOS app data (Reminders, Calendar, Contacts)
/// and direct SQLite access for Notes and iMessage databases. This bypasses AppleScript entirely,
/// avoiding the TCC automation dialogs that hang when triggered programmatically.
actor NativeDataAccessService {
    static let shared = NativeDataAccessService()

    private let eventStore = EKEventStore()
    private let contactStore = CNContactStore()

    // MARK: - Reminders (EventKit)

    struct ReminderItem: Sendable {
        let title: String
        let listName: String
        let dueDate: Date?
        let isCompleted: Bool
        let priority: Int
        let notes: String?
    }

    func requestRemindersAccess() async throws -> Bool {
        if #available(macOS 14.0, *) {
            return try await eventStore.requestFullAccessToReminders()
        } else {
            return try await eventStore.requestAccess(to: .reminder)
        }
    }

    func fetchReminders(
        includeCompleted: Bool = false,
        listName: String? = nil,
        limit: Int = 100
    ) async throws -> [ReminderItem] {
        let granted = try await requestRemindersAccess()
        guard granted else {
            throw NativeDataAccessError.permissionDenied("Reminders")
        }

        let calendars: [EKCalendar]?
        if let listName {
            let matching = eventStore.calendars(for: .reminder).filter {
                $0.title.localizedCaseInsensitiveCompare(listName) == .orderedSame
            }
            calendars = matching.isEmpty ? nil : matching
        } else {
            calendars = nil
        }

        let predicate = eventStore.predicateForReminders(in: calendars)

        let ekReminders: [EKReminder] = try await withCheckedThrowingContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                if let reminders {
                    continuation.resume(returning: reminders)
                } else {
                    continuation.resume(throwing: NativeDataAccessError.fetchFailed("Reminders"))
                }
            }
        }

        var results: [ReminderItem] = []
        for reminder in ekReminders {
            if !includeCompleted && reminder.isCompleted { continue }
            results.append(ReminderItem(
                title: reminder.title ?? "(untitled)",
                listName: reminder.calendar?.title ?? "Unknown",
                dueDate: reminder.dueDateComponents?.date,
                isCompleted: reminder.isCompleted,
                priority: reminder.priority,
                notes: reminder.notes
            ))
            if results.count >= limit { break }
        }
        return results
    }

    func fetchOverdueReminders(limit: Int = 50) async throws -> [ReminderItem] {
        let all = try await fetchReminders(includeCompleted: false, limit: 500)
        let now = Date()
        let overdue = all.filter { item in
            guard let due = item.dueDate else { return false }
            return due < now
        }
        return Array(overdue.prefix(limit))
    }

    func addReminder(
        title: String,
        listName: String? = nil,
        dueDate: String? = nil,
        notes: String? = nil,
        priority: Int = 0
    ) async throws -> String {
        let granted = try await requestRemindersAccess()
        guard granted else {
            throw NativeDataAccessError.permissionDenied("Reminders")
        }

        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = title
        reminder.notes = notes
        reminder.priority = priority

        if let listName {
            let matching = eventStore.calendars(for: .reminder).first {
                $0.title.localizedCaseInsensitiveCompare(listName) == .orderedSame
            }
            reminder.calendar = matching ?? eventStore.defaultCalendarForNewReminders()
        } else {
            reminder.calendar = eventStore.defaultCalendarForNewReminders()
        }

        if let dueDate, let date = ISO8601DateFormatter().date(from: dueDate) {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: date
            )
        }

        try eventStore.save(reminder, commit: true)
        return "Created reminder: \(title)"
    }

    func completeReminder(title: String) async throws -> String {
        let granted = try await requestRemindersAccess()
        guard granted else {
            throw NativeDataAccessError.permissionDenied("Reminders")
        }

        let predicate = eventStore.predicateForReminders(in: nil)
        let reminders: [EKReminder] = try await withCheckedThrowingContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }

        guard let match = reminders.first(where: {
            !$0.isCompleted && ($0.title ?? "").localizedCaseInsensitiveCompare(title) == .orderedSame
        }) else {
            throw NativeDataAccessError.notFound("Reminder '\(title)' not found or already completed.")
        }

        match.isCompleted = true
        try eventStore.save(match, commit: true)
        return "Completed reminder: \(title)"
    }

    // MARK: - Calendar (EventKit) — Read support

    struct CalendarEvent: Sendable {
        let title: String
        let calendarName: String
        let startDate: Date
        let endDate: Date
        let location: String?
        let notes: String?
        let isAllDay: Bool
    }

    func requestCalendarAccess() async throws -> Bool {
        if #available(macOS 14.0, *) {
            return try await eventStore.requestFullAccessToEvents()
        } else {
            return try await eventStore.requestAccess(to: .event)
        }
    }

    func fetchCalendarEvents(
        from startDate: Date,
        to endDate: Date,
        calendarName: String? = nil,
        limit: Int = 50
    ) async throws -> [CalendarEvent] {
        let granted = try await requestCalendarAccess()
        guard granted else {
            throw NativeDataAccessError.permissionDenied("Calendar")
        }

        let calendars: [EKCalendar]?
        if let calendarName {
            let matching = eventStore.calendars(for: .event).filter {
                $0.title.localizedCaseInsensitiveCompare(calendarName) == .orderedSame
            }
            calendars = matching.isEmpty ? nil : matching
        } else {
            calendars = nil
        }

        let predicate = eventStore.predicateForEvents(
            withStart: startDate,
            end: endDate,
            calendars: calendars
        )

        let events = eventStore.events(matching: predicate)
            .prefix(limit)
            .map { event in
                CalendarEvent(
                    title: event.title ?? "(untitled)",
                    calendarName: event.calendar?.title ?? "Unknown",
                    startDate: event.startDate,
                    endDate: event.endDate,
                    location: event.location,
                    notes: event.notes,
                    isAllDay: event.isAllDay
                )
            }
        return Array(events)
    }

    func fetchTodayEvents() async throws -> [CalendarEvent] {
        let now = Date()
        let endOfDay = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: now)!
        return try await fetchCalendarEvents(from: now, to: endOfDay)
    }

    func fetchUpcomingEvents(days: Int = 7) async throws -> [CalendarEvent] {
        let now = Date()
        let future = Calendar.current.date(byAdding: .day, value: days, to: now)!
        return try await fetchCalendarEvents(from: now, to: future)
    }

    func createCalendarEvent(
        title: String,
        startISO8601: String,
        endISO8601: String,
        calendarName: String? = nil,
        location: String? = nil,
        notes: String? = nil
    ) async throws -> String {
        let granted = try await requestCalendarAccess()
        guard granted else {
            throw NativeDataAccessError.permissionDenied("Calendar")
        }

        let formatter = ISO8601DateFormatter()
        guard let start = formatter.date(from: startISO8601) else {
            throw NativeDataAccessError.invalidInput("Invalid start date: \(startISO8601)")
        }
        guard let end = formatter.date(from: endISO8601) else {
            throw NativeDataAccessError.invalidInput("Invalid end date: \(endISO8601)")
        }

        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.location = location
        event.notes = notes

        if let calendarName {
            let matching = eventStore.calendars(for: .event).first {
                $0.title.localizedCaseInsensitiveCompare(calendarName) == .orderedSame
            }
            event.calendar = matching ?? eventStore.defaultCalendarForNewEvents
        } else {
            event.calendar = eventStore.defaultCalendarForNewEvents
        }

        try eventStore.save(event, span: .thisEvent)
        return "Created calendar event: \(title)"
    }

    // MARK: - Contacts (CNContactStore)

    struct ContactInfo: Sendable {
        let fullName: String
        let phoneNumbers: [String]
        let emailAddresses: [String]
        let organization: String?
    }

    func requestContactsAccess() async throws -> Bool {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .authorized { return true }
        return try await withCheckedThrowingContinuation { continuation in
            contactStore.requestAccess(for: .contacts) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    func searchContacts(query: String, limit: Int = 20) async throws -> [ContactInfo] {
        let granted = try await requestContactsAccess()
        guard granted else {
            throw NativeDataAccessError.permissionDenied("Contacts")
        }

        let keysToFetch: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName)
        ]

        let predicate = CNContact.predicateForContacts(matchingName: query)
        let contacts = try contactStore.unifiedContacts(matching: predicate, keysToFetch: keysToFetch)

        return contacts.prefix(limit).map { contact in
            ContactInfo(
                fullName: CNContactFormatter.string(from: contact, style: .fullName) ?? "\(contact.givenName) \(contact.familyName)",
                phoneNumbers: contact.phoneNumbers.map { $0.value.stringValue },
                emailAddresses: contact.emailAddresses.map { $0.value as String },
                organization: contact.organizationName.isEmpty ? nil : contact.organizationName
            )
        }
    }

    // MARK: - Notes (Direct SQLite Access)

    struct NoteItem: Sendable {
        let title: String
        let snippet: String
        let folderName: String
        let modifiedDate: Date?
    }

    func fetchNotes(query: String? = nil, limit: Int = 20) async throws -> [NoteItem] {
        let dbPath = Self.notesDBPath()
        guard let dbPath else {
            throw NativeDataAccessError.databaseNotFound("Notes")
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let notes = try Self.queryNotesDB(path: dbPath, query: query, limit: limit)
                    continuation.resume(returning: notes)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func notesDBPath() -> String? {
        let groupContainer = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.notes")
        let dbFile = groupContainer.appendingPathComponent("NoteStore.sqlite")
        if FileManager.default.fileExists(atPath: dbFile.path) {
            return dbFile.path
        }
        return nil
    }

    private static func queryNotesDB(path: String, query: String?, limit: Int) throws -> [NoteItem] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw NativeDataAccessError.databaseNotFound("Notes (cannot open database)")
        }
        defer { sqlite3_close(db) }

        var sql = """
        SELECT
            n.ZTITLE1,
            SUBSTR(nb.ZTEXT1, 1, 200),
            f.ZTITLE2,
            n.ZMODIFICATIONDATE1
        FROM ZICCLOUDSYNCINGOBJECT n
        LEFT JOIN ZICCLOUDSYNCINGOBJECT nb ON nb.ZNOTE = n.Z_PK
        LEFT JOIN ZICCLOUDSYNCINGOBJECT f ON n.ZFOLDER = f.Z_PK
        WHERE n.ZTITLE1 IS NOT NULL
            AND n.ZMARKEDFORDELETION != 1
        """

        if let query, !query.isEmpty {
            let escaped = query.replacingOccurrences(of: "'", with: "''")
            sql += " AND (n.ZTITLE1 LIKE '%\(escaped)%' COLLATE NOCASE OR nb.ZTEXT1 LIKE '%\(escaped)%' COLLATE NOCASE)"
        }

        sql += " ORDER BY n.ZMODIFICATIONDATE1 DESC LIMIT \(limit)"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let errMsg = String(cString: sqlite3_errmsg(db))
            throw NativeDataAccessError.fetchFailed("Notes query failed: \(errMsg)")
        }
        defer { sqlite3_finalize(stmt) }

        var notes: [NoteItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let title = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "(untitled)"
            let snippet = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let folder = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "Notes"

            var modDate: Date?
            if sqlite3_column_type(stmt, 3) != SQLITE_NULL {
                // Core Data timestamp: seconds since 2001-01-01
                let timestamp = sqlite3_column_double(stmt, 3)
                modDate = Date(timeIntervalSinceReferenceDate: timestamp)
            }

            notes.append(NoteItem(
                title: title,
                snippet: snippet.trimmingCharacters(in: .whitespacesAndNewlines),
                folderName: folder,
                modifiedDate: modDate
            ))
        }
        return notes
    }

    // MARK: - iMessage (Direct SQLite Access)

    struct MessageItem: Sendable {
        let text: String
        let sender: String
        let chatName: String
        let date: Date?
        let isFromMe: Bool
    }

    func fetchRecentMessages(chatName: String? = nil, limit: Int = 20) async throws -> [MessageItem] {
        let dbPath = Self.messagesDBPath()
        guard let dbPath else {
            throw NativeDataAccessError.databaseNotFound("Messages")
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let messages = try Self.queryMessagesDB(path: dbPath, chatName: chatName, limit: limit)
                    continuation.resume(returning: messages)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func searchMessages(query: String, limit: Int = 20) async throws -> [MessageItem] {
        let dbPath = Self.messagesDBPath()
        guard let dbPath else {
            throw NativeDataAccessError.databaseNotFound("Messages")
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let messages = try Self.searchMessagesDB(path: dbPath, query: query, limit: limit)
                    continuation.resume(returning: messages)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func listMessageChats(limit: Int = 30) async throws -> [String] {
        let dbPath = Self.messagesDBPath()
        guard let dbPath else {
            throw NativeDataAccessError.databaseNotFound("Messages")
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let chats = try Self.listChatsDB(path: dbPath, limit: limit)
                    continuation.resume(returning: chats)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func messagesDBPath() -> String? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Messages/chat.db").path
        if FileManager.default.isReadableFile(atPath: path) {
            return path
        }
        return nil
    }

    private static func queryMessagesDB(path: String, chatName: String?, limit: Int) throws -> [MessageItem] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw NativeDataAccessError.databaseNotFound("Messages (cannot open database — Full Disk Access may be required)")
        }
        defer { sqlite3_close(db) }

        var sql = """
        SELECT
            m.text,
            COALESCE(h.id, 'Me') AS sender,
            COALESCE(c.display_name, c.chat_identifier, 'Unknown') AS chat_name,
            m.date / 1000000000 + 978307200 AS unix_date,
            m.is_from_me
        FROM message m
        LEFT JOIN handle h ON m.handle_id = h.ROWID
        LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
        LEFT JOIN chat c ON cmj.chat_id = c.ROWID
        WHERE m.text IS NOT NULL AND m.text != ''
        """

        if let chatName, !chatName.isEmpty {
            let escaped = chatName.replacingOccurrences(of: "'", with: "''")
            sql += " AND (c.display_name LIKE '%\(escaped)%' COLLATE NOCASE OR c.chat_identifier LIKE '%\(escaped)%' COLLATE NOCASE OR h.id LIKE '%\(escaped)%' COLLATE NOCASE)"
        }

        sql += " ORDER BY m.date DESC LIMIT \(limit)"

        return try executeMessageQuery(db: db, sql: sql)
    }

    private static func searchMessagesDB(path: String, query: String, limit: Int) throws -> [MessageItem] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw NativeDataAccessError.databaseNotFound("Messages (cannot open database — Full Disk Access may be required)")
        }
        defer { sqlite3_close(db) }

        let escaped = query.replacingOccurrences(of: "'", with: "''")
        // Search in message text, sender handle, chat display name, and chat identifier
        let sql = """
        SELECT
            m.text,
            COALESCE(h.id, 'Me') AS sender,
            COALESCE(c.display_name, c.chat_identifier, 'Unknown') AS chat_name,
            m.date / 1000000000 + 978307200 AS unix_date,
            m.is_from_me
        FROM message m
        LEFT JOIN handle h ON m.handle_id = h.ROWID
        LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
        LEFT JOIN chat c ON cmj.chat_id = c.ROWID
        WHERE m.text LIKE '%\(escaped)%' COLLATE NOCASE
           OR h.id LIKE '%\(escaped)%' COLLATE NOCASE
           OR c.display_name LIKE '%\(escaped)%' COLLATE NOCASE
           OR c.chat_identifier LIKE '%\(escaped)%' COLLATE NOCASE
        ORDER BY m.date DESC
        LIMIT \(limit)
        """

        return try executeMessageQuery(db: db, sql: sql)
    }

    /// Resolves a contact name to phone numbers/emails via CNContactStore,
    /// then searches Messages by those identifiers.
    func searchMessagesByContactName(name: String, limit: Int = 20) async throws -> [MessageItem] {
        // First, resolve the contact name to phone numbers and emails
        let contacts = try await searchContacts(query: name, limit: 5)
        var identifiers: [String] = []
        for contact in contacts {
            identifiers.append(contentsOf: contact.phoneNumbers)
            identifiers.append(contentsOf: contact.emailAddresses)
        }

        guard !identifiers.isEmpty else {
            // No matching contact found — fall back to text search
            return try await searchMessages(query: name, limit: limit)
        }

        let dbPath = Self.messagesDBPath()
        guard let dbPath else {
            throw NativeDataAccessError.databaseNotFound("Messages")
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let messages = try Self.queryMessagesByIdentifiers(
                        path: dbPath,
                        identifiers: identifiers,
                        limit: limit
                    )
                    continuation.resume(returning: messages)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func queryMessagesByIdentifiers(path: String, identifiers: [String], limit: Int) throws -> [MessageItem] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw NativeDataAccessError.databaseNotFound("Messages (cannot open database)")
        }
        defer { sqlite3_close(db) }

        // Build OR conditions for each identifier (phone number or email)
        let conditions = identifiers.map { id -> String in
            let escaped = id.replacingOccurrences(of: "'", with: "''")
            // Normalize phone matching: strip non-digits for comparison
            let digits = escaped.filter(\.isNumber)
            if digits.count >= 7 {
                // Match by last 10 digits to handle +1, country codes, etc.
                let suffix = String(digits.suffix(10))
                return "(h.id LIKE '%\(suffix)%' OR c.chat_identifier LIKE '%\(suffix)%')"
            }
            return "(h.id LIKE '%\(escaped)%' OR c.chat_identifier LIKE '%\(escaped)%')"
        }.joined(separator: " OR ")

        let sql = """
        SELECT
            m.text,
            COALESCE(h.id, 'Me') AS sender,
            COALESCE(c.display_name, c.chat_identifier, 'Unknown') AS chat_name,
            m.date / 1000000000 + 978307200 AS unix_date,
            m.is_from_me
        FROM message m
        LEFT JOIN handle h ON m.handle_id = h.ROWID
        LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
        LEFT JOIN chat c ON cmj.chat_id = c.ROWID
        WHERE m.text IS NOT NULL AND m.text != ''
          AND (\(conditions))
        ORDER BY m.date DESC
        LIMIT \(limit)
        """

        return try executeMessageQuery(db: db, sql: sql)
    }

    private static func listChatsDB(path: String, limit: Int) throws -> [String] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw NativeDataAccessError.databaseNotFound("Messages (cannot open database — Full Disk Access may be required)")
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT COALESCE(c.display_name, c.chat_identifier) AS name
        FROM chat c
        JOIN chat_message_join cmj ON c.ROWID = cmj.chat_id
        GROUP BY c.ROWID
        ORDER BY MAX(cmj.message_date) DESC
        LIMIT \(limit)
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NativeDataAccessError.fetchFailed("Could not list chats")
        }
        defer { sqlite3_finalize(stmt) }

        var chats: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = sqlite3_column_text(stmt, 0) {
                chats.append(String(cString: name))
            }
        }
        return chats
    }

    private static func executeMessageQuery(db: OpaquePointer?, sql: String) throws -> [MessageItem] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let errMsg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw NativeDataAccessError.fetchFailed("Messages query failed: \(errMsg)")
        }
        defer { sqlite3_finalize(stmt) }

        var messages: [MessageItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let text = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let sender = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "Unknown"
            let chatName = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "Unknown"
            let unixDate = sqlite3_column_double(stmt, 3)
            let isFromMe = sqlite3_column_int(stmt, 4) != 0

            messages.append(MessageItem(
                text: text,
                sender: isFromMe ? "Me" : sender,
                chatName: chatName,
                date: unixDate > 0 ? Date(timeIntervalSince1970: unixDate) : nil,
                isFromMe: isFromMe
            ))
        }
        return messages
    }

    // MARK: - Formatting Helpers

    static func formatReminders(_ reminders: [ReminderItem]) -> String {
        if reminders.isEmpty { return "No reminders found." }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        var lines: [String] = []
        for r in reminders {
            var line = "- \(r.title)"
            if let due = r.dueDate {
                line += " | Due: \(formatter.string(from: due))"
            }
            line += " [\(r.listName)]"
            if r.isCompleted { line += " ✓" }
            if let notes = r.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                line += "\n  Notes: \(notes)"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    static func formatCalendarEvents(_ events: [CalendarEvent]) -> String {
        if events.isEmpty { return "No events found." }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        var lines: [String] = []
        for e in events {
            var line = "- \(e.title)"
            if e.isAllDay {
                line += " (all day)"
            } else {
                line += " | \(formatter.string(from: e.startDate)) – \(formatter.string(from: e.endDate))"
            }
            line += " [\(e.calendarName)]"
            if let loc = e.location, !loc.isEmpty { line += " @ \(loc)" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    static func formatContacts(_ contacts: [ContactInfo]) -> String {
        if contacts.isEmpty { return "No contacts found." }

        var lines: [String] = []
        for c in contacts {
            var line = "- \(c.fullName)"
            if let org = c.organization { line += " (\(org))" }
            if !c.phoneNumbers.isEmpty { line += "\n  Phone: \(c.phoneNumbers.joined(separator: ", "))" }
            if !c.emailAddresses.isEmpty { line += "\n  Email: \(c.emailAddresses.joined(separator: ", "))" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    static func formatNotes(_ notes: [NoteItem]) -> String {
        if notes.isEmpty { return "No notes found." }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        var lines: [String] = []
        for n in notes {
            var line = "- \(n.title) [\(n.folderName)]"
            if let mod = n.modifiedDate { line += " (modified \(formatter.string(from: mod)))" }
            if !n.snippet.isEmpty {
                let trimmed = n.snippet.prefix(120)
                line += "\n  \(trimmed)\(n.snippet.count > 120 ? "..." : "")"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    static func formatMessages(_ messages: [MessageItem]) -> String {
        if messages.isEmpty { return "No messages found." }

        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short

        var lines: [String] = []
        for m in messages {
            let dateStr = m.date.map { formatter.string(from: $0) } ?? "unknown"
            let sender = m.isFromMe ? "Me" : m.sender
            let text = m.text.prefix(200)
            lines.append("[\(dateStr)] \(sender) in \(m.chatName): \(text)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Errors

enum NativeDataAccessError: LocalizedError {
    case permissionDenied(String)
    case databaseNotFound(String)
    case fetchFailed(String)
    case notFound(String)
    case invalidInput(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied(let app):
            return "Open Assist needs permission to access \(app). macOS will prompt you to grant access, or you can enable it in System Settings > Privacy & Security."
        case .databaseNotFound(let app):
            return "Could not find the \(app) database. This may require Full Disk Access — grant it in System Settings > Privacy & Security > Full Disk Access."
        case .fetchFailed(let detail):
            return "Failed to read data: \(detail)"
        case .notFound(let detail):
            return detail
        case .invalidInput(let detail):
            return detail
        }
    }
}
