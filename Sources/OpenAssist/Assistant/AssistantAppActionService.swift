import AppKit
import Foundation

enum AssistantAppActionToolDefinition {
    static let name = "app_action"
    static let toolKind = "appAction"

    static let description = """
    Perform a direct action in supported Mac apps: Finder, Terminal, Calendar, System Settings, Reminders, Contacts, Notes, or Messages. Use this tool for supported app-specific work only. For Reminders, Contacts, Notes, and Messages, this tool reads data directly via native frameworks — no AppleScript needed.
    """

    static let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "task": [
                "type": "string",
                "description": "What to do."
            ],
            "app": [
                "type": "string",
                "description": "Supported apps: Finder, Terminal, Calendar, System Settings, Reminders, Contacts, Notes, Messages."
            ],
            "query": [
                "type": "string",
                "description": "Search query for Contacts, Notes, or Messages."
            ],
            "list": [
                "type": "string",
                "description": "Reminder list name or calendar name to filter by."
            ],
            "chat": [
                "type": "string",
                "description": "Chat/conversation name for Messages."
            ],
            "action": [
                "type": "string",
                "description": "Optional action hint such as reveal, open, run, preview, create, or open_settings."
            ],
            "path": [
                "type": "string",
                "description": "File or folder path for Finder actions."
            ],
            "command": [
                "type": "string",
                "description": "Terminal command to run."
            ],
            "title": [
                "type": "string",
                "description": "Calendar event title."
            ],
            "start": [
                "type": "string",
                "description": "Calendar event start date in ISO 8601."
            ],
            "end": [
                "type": "string",
                "description": "Calendar event end date in ISO 8601."
            ],
            "notes": [
                "type": "string",
                "description": "Optional calendar event notes."
            ],
            "pane": [
                "type": "string",
                "description": "System Settings pane or search query."
            ],
            "commit": [
                "type": "boolean",
                "description": "For Calendar actions, true creates the event and false returns a draft preview."
            ]
        ],
        "required": ["task"],
        "additionalProperties": true
    ]

    static func dynamicToolSpec() -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": inputSchema
        ]
    }
}

actor AssistantAppActionService {
    enum SupportedApp: String, Sendable {
        case finder
        case terminal
        case calendar
        case systemSettings
        case reminders
        case contacts
        case notes
        case messages

        var displayName: String {
            switch self {
            case .finder: return "Finder"
            case .terminal: return "Terminal"
            case .calendar: return "Calendar"
            case .systemSettings: return "System Settings"
            case .reminders: return "Reminders"
            case .contacts: return "Contacts"
            case .notes: return "Notes"
            case .messages: return "Messages"
            }
        }

        /// Apps that use native frameworks (EventKit, Contacts, SQLite) instead of AppleScript.
        var usesNativeAccess: Bool {
            switch self {
            case .reminders, .contacts, .notes, .messages: return true
            default: return false
            }
        }
    }

    struct ParsedRequest: Equatable, Sendable {
        let task: String
        let app: SupportedApp?
        let action: String?
        let path: String?
        let command: String?
        let title: String?
        let start: String?
        let end: String?
        let notes: String?
        let pane: String?
        let commit: Bool
        let query: String?
        let list: String?
        let chat: String?

        var normalizedTask: String {
            task.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }

        var needsComputerFallback: Bool {
            let fallbackSignals = ["click", "drag", "scroll", "type into", "fill", "choose from", "submit"]
            return fallbackSignals.contains(where: normalizedTask.contains)
        }
    }

    private let helper: LocalAutomationHelper

    init(helper: LocalAutomationHelper = .shared) {
        self.helper = helper
    }

    func run(arguments: Any, preferredModelID: String?) async -> AssistantToolExecutionResult {
        do {
            let request = try Self.parseRequest(from: arguments)

            // Block privacy-protected apps immediately — no live-control fallback
            if let blockedApp = Self.detectPrivacyBlockedApp(in: request.task) {
                return Self.result(
                    summary: """
                    Open Assist cannot access \(blockedApp) because macOS blocks automation and file access \
                    to this app without explicit privacy permissions. This is a macOS restriction that cannot \
                    be worked around. Please open \(blockedApp) manually to view its contents.
                    """,
                    detail: nil,
                    success: false
                )
            }

            if request.needsComputerFallback {
                return Self.result(
                    summary: """
                    Open Assist can only use direct app actions here. This request needs live clicking or typing, which Open Assist no longer supports.
                    """,
                    detail: """
                    Try a direct supported action instead, like Finder open/reveal, Terminal run command, Calendar read/create, System Settings open, Reminders, Contacts, Notes, or Messages.
                    """,
                    success: false
                )
            }

            guard let app = request.app else {
                return Self.result(
                    summary: "App Action only works with supported direct Mac apps.",
                    detail: "Choose Finder, Terminal, Calendar, System Settings, Reminders, Contacts, Notes, or Messages.",
                    success: false
                )
            }

            switch app {
            case .finder:
                return try await runFinderAction(request)
            case .terminal:
                return try await runTerminalAction(request)
            case .calendar:
                return try await runCalendarAction(request)
            case .systemSettings:
                return try await runSystemSettingsAction(request)
            case .reminders:
                return try await runRemindersAction(request)
            case .contacts:
                return try await runContactsAction(request)
            case .notes:
                return try await runNotesAction(request)
            case .messages:
                return try await runMessagesAction(request)
            }
        } catch {
            let summary = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                ?? "App Action failed."
            return Self.result(summary: summary, detail: nil, success: false)
        }
    }

    static func parseRequest(from arguments: Any) throws -> ParsedRequest {
        if let text = (arguments as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return ParsedRequest(
                task: text,
                app: inferApp(from: text),
                action: nil,
                path: nil,
                command: nil,
                title: nil,
                start: nil,
                end: nil,
                notes: nil,
                pane: nil,
                commit: false,
                query: nil,
                list: nil,
                chat: nil
            )
        }

        guard let dictionary = arguments as? [String: Any] else {
            throw LocalAutomationError.invalidArguments("App Action needs a task.")
        }

        let task = [
            dictionary["task"] as? String,
            dictionary["goal"] as? String,
            dictionary["instruction"] as? String,
            dictionary["prompt"] as? String
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first(where: { !$0.isEmpty })

        guard let task else {
            throw LocalAutomationError.invalidArguments("App Action needs a task.")
        }

        let rawApp = [
            dictionary["app"] as? String,
            dictionary["application"] as? String
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first(where: { !$0.isEmpty })

        return ParsedRequest(
            task: task,
            app: rawApp.flatMap(inferApp(from:)) ?? inferApp(from: task),
            action: (dictionary["action"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            path: (dictionary["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            command: (dictionary["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            title: (dictionary["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            start: (dictionary["start"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            end: (dictionary["end"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            notes: (dictionary["notes"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            pane: (dictionary["pane"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            commit: dictionary["commit"] as? Bool ?? false,
            query: (dictionary["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            list: (dictionary["list"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            chat: (dictionary["chat"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        )
    }

    /// Apps that macOS protects with privacy consent dialogs that hang when scripted.
    /// Note: Reminders, Contacts, Notes, and Messages are no longer blocked — they now
    /// use native framework access (EventKit, CNContactStore, direct SQLite).
    private static let privacyBlockedApps: [(keyword: String, displayName: String)] = [
        ("mail", "Mail"),
        ("photos", "Photos"),
        ("safari", "Safari"),
        ("music", "Music"),
        ("podcasts", "Podcasts"),
        ("home", "Home"),
        ("health", "Health"),
    ]

    /// Returns the display name of a privacy-blocked app if the task text targets one.
    static func detectPrivacyBlockedApp(in taskText: String) -> String? {
        let normalized = taskText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for entry in privacyBlockedApps {
            if normalized.contains(entry.keyword) {
                return entry.displayName
            }
        }
        return nil
    }

    private static func inferApp(from text: String) -> SupportedApp? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.contains("reminder") || normalized.contains("overdue") || normalized.contains("to-do") || normalized.contains("todo") {
            return .reminders
        }
        if normalized.contains("contact") || normalized.contains("phone number") || normalized.contains("email address") {
            return .contacts
        }
        if normalized.contains("note") && !normalized.contains("notification") {
            return .notes
        }
        if normalized.contains("imessage") || normalized.contains("message") || normalized.contains("text from") || normalized.contains("sms") {
            return .messages
        }
        if normalized.contains("finder") || normalized.contains("folder") || normalized.contains("file") {
            return .finder
        }
        if normalized.contains("terminal") || normalized.contains("shell") || normalized.contains("run command") {
            return .terminal
        }
        if normalized.contains("calendar") || normalized.contains("event") || normalized.contains("meeting") {
            return .calendar
        }
        if normalized.contains("system settings") || normalized.contains("settings") || normalized.contains("preferences") {
            return .systemSettings
        }
        return nil
    }

    private func runFinderAction(_ request: ParsedRequest) async throws -> AssistantToolExecutionResult {
        let action = request.action?.lowercased() ?? ""
        guard let path = request.path ?? extractQuotedPath(from: request.task) else {
            throw LocalAutomationError.invalidArguments("Finder actions need a file or folder path.")
        }

        if action.contains("reveal") || request.normalizedTask.contains("reveal") || request.normalizedTask.contains("select") {
            try await helper.revealInFinder(path: path)
            return Self.result(summary: "Revealed \(path) in Finder.", detail: nil)
        }

        try await helper.openInFinder(path: path)
        return Self.result(summary: "Opened \(path) in Finder.", detail: nil)
    }

    private func runTerminalAction(_ request: ParsedRequest) async throws -> AssistantToolExecutionResult {
        guard let command = request.command ?? extractCommand(from: request.task) else {
            throw LocalAutomationError.invalidArguments("Terminal actions need a command.")
        }
        try await helper.runTerminalCommand(command)
        return Self.result(summary: "Opened Terminal and ran the command.", detail: command)
    }

    private func runCalendarAction(_ request: ParsedRequest) async throws -> AssistantToolExecutionResult {
        let action = request.action?.lowercased() ?? ""
        let normalized = request.normalizedTask

        // Read: fetch today's events, upcoming events, or events in a date range
        if action.contains("list") || action.contains("read") || action.contains("fetch") || action.contains("show")
            || normalized.contains("today") || normalized.contains("upcoming") || normalized.contains("schedule")
            || normalized.contains("what") || normalized.contains("show") || normalized.contains("list")
            || (request.title == nil && request.start == nil && !request.commit) {

            if normalized.contains("today") || normalized.contains("today's") {
                let events = try await nativeService.fetchTodayEvents()
                let formatted = NativeDataAccessService.formatCalendarEvents(events)
                return Self.result(
                    summary: events.isEmpty ? "No events today." : "Found \(events.count) event(s) for today.",
                    detail: formatted
                )
            }

            let days = normalized.contains("week") ? 7 : (normalized.contains("month") ? 30 : 7)
            let events = try await nativeService.fetchUpcomingEvents(days: days)
            let formatted = NativeDataAccessService.formatCalendarEvents(events)
            return Self.result(
                summary: events.isEmpty ? "No upcoming events." : "Found \(events.count) upcoming event(s).",
                detail: formatted
            )
        }

        // Write: create a calendar event (native EventKit)
        guard let title = request.title ?? inferredCalendarTitle(from: request.task),
              let start = request.start,
              let end = request.end else {
            throw LocalAutomationError.invalidArguments("Calendar actions need a title, start date, and end date in ISO 8601.")
        }

        if request.commit {
            let result = try await nativeService.createCalendarEvent(
                title: title,
                startISO8601: start,
                endISO8601: end,
                calendarName: request.list,
                notes: request.notes
            )
            return Self.result(summary: result, detail: nil)
        }

        let preview = try await helper.previewCalendarEvent(
            title: title,
            startISO8601: start,
            endISO8601: end,
            notes: request.notes
        )
        return Self.result(
            summary: "Prepared a Calendar event draft. Review it, then rerun with commit=true to create it.",
            detail: preview
        )
    }

    private func runSystemSettingsAction(_ request: ParsedRequest) async throws -> AssistantToolExecutionResult {
        let pane = request.pane ?? request.action ?? request.task
        await helper.openSystemSettings(pane: pane)
        return Self.result(summary: "Opened System Settings.", detail: pane)
    }

    // MARK: - Native Framework Actions (Reminders, Contacts, Notes, Messages)

    private let nativeService = NativeDataAccessService.shared

    private func runRemindersAction(_ request: ParsedRequest) async throws -> AssistantToolExecutionResult {
        let action = request.action?.lowercased() ?? ""
        let normalized = request.normalizedTask

        // Complete a reminder
        if action.contains("complete") || action.contains("done") || action.contains("finish")
            || normalized.contains("complete") || normalized.contains("mark as done") {
            guard let title = request.title ?? extractQuotedString(from: request.task) else {
                throw LocalAutomationError.invalidArguments("Completing a reminder needs a title.")
            }
            let result = try await nativeService.completeReminder(title: title)
            return Self.result(summary: result, detail: nil)
        }

        // Add a reminder
        if action.contains("add") || action.contains("create") || action.contains("new")
            || normalized.contains("add") || normalized.contains("create") || request.commit {
            guard let title = request.title ?? extractQuotedString(from: request.task) else {
                throw LocalAutomationError.invalidArguments("Creating a reminder needs a title.")
            }
            let result = try await nativeService.addReminder(
                title: title,
                listName: request.list,
                dueDate: request.start,
                notes: request.notes,
                priority: 0
            )
            return Self.result(summary: result, detail: nil)
        }

        // Fetch overdue reminders
        if normalized.contains("overdue") || normalized.contains("past due") || normalized.contains("late") {
            let reminders = try await nativeService.fetchOverdueReminders()
            let formatted = NativeDataAccessService.formatReminders(reminders)
            return Self.result(
                summary: reminders.isEmpty ? "No overdue reminders." : "Found \(reminders.count) overdue reminder(s).",
                detail: formatted
            )
        }

        // Default: list reminders
        let reminders = try await nativeService.fetchReminders(
            includeCompleted: normalized.contains("completed") || normalized.contains("all"),
            listName: request.list
        )
        let formatted = NativeDataAccessService.formatReminders(reminders)
        return Self.result(
            summary: reminders.isEmpty ? "No reminders found." : "Found \(reminders.count) reminder(s).",
            detail: formatted
        )
    }

    private func runContactsAction(_ request: ParsedRequest) async throws -> AssistantToolExecutionResult {
        let searchQuery = request.query ?? request.title ?? extractQuotedString(from: request.task) ?? request.task
        let contacts = try await nativeService.searchContacts(query: searchQuery)
        let formatted = NativeDataAccessService.formatContacts(contacts)
        return Self.result(
            summary: contacts.isEmpty ? "No contacts found for '\(searchQuery)'." : "Found \(contacts.count) contact(s).",
            detail: formatted
        )
    }

    private func runNotesAction(_ request: ParsedRequest) async throws -> AssistantToolExecutionResult {
        do {
            let searchQuery = request.query ?? request.title ?? extractQuotedString(from: request.task)
            let notes = try await nativeService.fetchNotes(query: searchQuery)
            let formatted = NativeDataAccessService.formatNotes(notes)
            return Self.result(
                summary: notes.isEmpty ? "No notes found." : "Found \(notes.count) note(s).",
                detail: formatted
            )
        } catch let error as NativeDataAccessError {
            let userOpened = await Self.promptForFullDiskAccess(appName: "Notes")
            return Self.fullDiskAccessErrorResult(error: error, userOpenedSettings: userOpened)
        }
    }

    private func runMessagesAction(_ request: ParsedRequest) async throws -> AssistantToolExecutionResult {
        do {
            return try await runMessagesActionInner(request)
        } catch let error as NativeDataAccessError {
            let userOpened = await Self.promptForFullDiskAccess(appName: "Messages")
            return Self.fullDiskAccessErrorResult(error: error, userOpenedSettings: userOpened)
        }
    }

    private func runMessagesActionInner(_ request: ParsedRequest) async throws -> AssistantToolExecutionResult {
        let action = request.action?.lowercased() ?? ""
        let normalized = request.normalizedTask

        // List chats
        if action.contains("list") || action.contains("chats") || normalized.contains("list") || normalized.contains("conversations") || normalized.contains("chats") {
            let chats = try await nativeService.listMessageChats()
            let formatted = chats.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
            return Self.result(
                summary: chats.isEmpty ? "No message conversations found." : "Found \(chats.count) conversation(s).",
                detail: formatted
            )
        }

        // Search messages — try contact-aware search first (resolves names to phone numbers)
        if let query = request.query, !query.isEmpty {
            let messages = try await nativeService.searchMessagesByContactName(name: query)
            let formatted = NativeDataAccessService.formatMessages(messages)
            return Self.result(
                summary: messages.isEmpty ? "No messages matching '\(query)'." : "Found \(messages.count) message(s) related to '\(query)'.",
                detail: formatted
            )
        }

        // Fetch recent messages from a specific person or chat
        let chatFilter = request.chat ?? extractQuotedString(from: request.task)
        if let chatFilter {
            // Try contact-aware lookup first
            let messages = try await nativeService.searchMessagesByContactName(name: chatFilter)
            if !messages.isEmpty {
                let formatted = NativeDataAccessService.formatMessages(messages)
                return Self.result(
                    summary: "Found \(messages.count) recent message(s) with \(chatFilter).",
                    detail: formatted
                )
            }
        }

        // Fallback: fetch recent messages with optional chat filter on raw identifiers
        let messages = try await nativeService.fetchRecentMessages(chatName: chatFilter)
        let formatted = NativeDataAccessService.formatMessages(messages)
        return Self.result(
            summary: messages.isEmpty ? "No messages found." : "Found \(messages.count) recent message(s).",
            detail: formatted
        )
    }

    private func extractQuotedString(from text: String) -> String? {
        // Extract text between quotes: "something" or 'something'
        for (open, close) in [("\"", "\""), ("'", "'"), ("\u{201C}", "\u{201D}")] {
            if let startRange = text.range(of: open),
               let endRange = text.range(of: close, range: startRange.upperBound..<text.endIndex) {
                let value = String(text[startRange.upperBound..<endRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    private func extractQuotedPath(from task: String) -> String? {
        let pattern = #""([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let nsRange = NSRange(task.startIndex..<task.endIndex, in: task)
        guard let match = regex.firstMatch(in: task, options: [], range: nsRange),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: task) else {
            return nil
        }
        return String(task[range]).trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    private func extractCommand(from task: String) -> String? {
        let markers = ["run ", "execute ", "command "]
        let normalized = task.lowercased()
        for marker in markers {
            if let range = normalized.range(of: marker) {
                let value = task[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    return value
                }
            }
        }
        return extractQuotedPath(from: task)
    }

    private func inferredCalendarTitle(from task: String) -> String? {
        let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Shows a user-friendly alert asking whether to open Full Disk Access settings.
    /// Returns `true` if the user chose to open settings.
    @MainActor
    private static func promptForFullDiskAccess(appName: String) async -> Bool {
        await MainActor.run {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Full Disk Access Required"
            alert.informativeText = "Open Assist needs Full Disk Access to read your \(appName) data. macOS does not allow apps to request this permission automatically — you need to enable it manually in System Settings.\n\nWould you like to open Full Disk Access settings now?"
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Not Now")

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                PermissionCenter.openFullDiskAccessSettings()
                return true
            }
            return false
        }
    }

    private static func fullDiskAccessErrorResult(
        error: NativeDataAccessError,
        userOpenedSettings: Bool
    ) -> AssistantToolExecutionResult {
        let action = userOpenedSettings
            ? "Opened Full Disk Access settings for the user. Tell them to add this app to the list, then try again."
            : "The user chose not to open settings right now."
        let message = "\(error.localizedDescription) \(action) There is no workaround -- do NOT try osascript or reading files manually."
        return result(summary: message, detail: nil, success: false)
    }

    private static func result(
        summary: String,
        detail: String?,
        success: Bool = true
    ) -> AssistantToolExecutionResult {
        var items: [AssistantToolExecutionResult.ContentItem] = [
            .init(type: "inputText", text: summary, imageURL: nil)
        ]
        if let detail {
            items.append(.init(type: "inputText", text: detail, imageURL: nil))
        }
        return AssistantToolExecutionResult(
            contentItems: items,
            success: success,
            summary: summary
        )
    }
}
