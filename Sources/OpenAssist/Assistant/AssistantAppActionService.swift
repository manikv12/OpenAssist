import Foundation

enum AssistantAppActionToolDefinition {
    static let name = "app_action"
    static let toolKind = "appAction"

    static let description = """
    Perform a direct action in supported Mac apps like Finder, Terminal, Calendar, or System Settings. Prefer this for app-specific work before falling back to general computer control.
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
                "description": "Supported apps: Finder, Terminal, Calendar, System Settings."
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

        var displayName: String {
            switch self {
            case .finder: return "Finder"
            case .terminal: return "Terminal"
            case .calendar: return "Calendar"
            case .systemSettings: return "System Settings"
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

        var normalizedTask: String {
            task.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }

        var needsComputerFallback: Bool {
            let fallbackSignals = ["click", "drag", "scroll", "type into", "fill", "choose from", "submit"]
            return fallbackSignals.contains(where: normalizedTask.contains)
        }
    }

    private let helper: LocalAutomationHelper
    private let computerUseService: AssistantComputerUseService

    init(
        helper: LocalAutomationHelper = .shared,
        computerUseService: AssistantComputerUseService
    ) {
        self.helper = helper
        self.computerUseService = computerUseService
    }

    func run(arguments: Any, preferredModelID: String?) async -> AssistantComputerUseService.ToolExecutionResult {
        do {
            let request = try Self.parseRequest(from: arguments)

            if request.needsComputerFallback {
                return await computerUseService.run(
                    arguments: [
                        "task": request.task,
                        "app": request.app?.displayName,
                        "reason": "Use the direct app action first when possible, then continue with computer control if needed."
                    ],
                    preferredModelID: preferredModelID
                )
            }

            guard let app = request.app else {
                return await computerUseService.run(
                    arguments: ["task": request.task],
                    preferredModelID: preferredModelID
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
                commit: false
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
            commit: dictionary["commit"] as? Bool ?? false
        )
    }

    private static func inferApp(from text: String) -> SupportedApp? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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

    private func runFinderAction(_ request: ParsedRequest) async throws -> AssistantComputerUseService.ToolExecutionResult {
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

    private func runTerminalAction(_ request: ParsedRequest) async throws -> AssistantComputerUseService.ToolExecutionResult {
        guard let command = request.command ?? extractCommand(from: request.task) else {
            throw LocalAutomationError.invalidArguments("Terminal actions need a command.")
        }
        try await helper.runTerminalCommand(command)
        return Self.result(summary: "Opened Terminal and ran the command.", detail: command)
    }

    private func runCalendarAction(_ request: ParsedRequest) async throws -> AssistantComputerUseService.ToolExecutionResult {
        guard let title = request.title ?? inferredCalendarTitle(from: request.task),
              let start = request.start,
              let end = request.end else {
            throw LocalAutomationError.invalidArguments("Calendar actions need a title, start date, and end date in ISO 8601.")
        }

        if request.commit {
            try await helper.createCalendarEvent(
                title: title,
                startISO8601: start,
                endISO8601: end,
                notes: request.notes
            )
            return Self.result(summary: "Created a Calendar event in your default calendar.", detail: title)
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

    private func runSystemSettingsAction(_ request: ParsedRequest) async throws -> AssistantComputerUseService.ToolExecutionResult {
        let pane = request.pane ?? request.action ?? request.task
        await helper.openSystemSettings(pane: pane)
        return Self.result(summary: "Opened System Settings.", detail: pane)
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

    private static func result(
        summary: String,
        detail: String?,
        success: Bool = true
    ) -> AssistantComputerUseService.ToolExecutionResult {
        var items: [AssistantComputerUseService.ToolExecutionResult.ContentItem] = [
            .init(type: "inputText", text: summary, imageURL: nil)
        ]
        if let detail {
            items.append(.init(type: "inputText", text: detail, imageURL: nil))
        }
        return AssistantComputerUseService.ToolExecutionResult(
            contentItems: items,
            success: success,
            summary: summary
        )
    }
}
