import Foundation

enum AssistantCommandSafetyClass: Equatable, Sendable {
    case readOnly
    case validation
    case mutatingOrUnknown
}

enum AssistantModePolicy {
    private static let simpleReadOnlyExecutables: Set<String> = [
        "pwd", "ls", "rg", "cat", "head", "tail", "grep",
        "sort", "uniq", "cut", "wc", "which", "mdfind", "stat",
        "file"
    ]

    private static let gitReadOnlyCommands: Set<String> = [
        "git status", "git diff", "git show", "git log", "git grep",
        "git ls-files", "git rev-parse", "git branch --show-current"
    ]

    private static let directObsidianReadOnlyCommands: Set<String> = [
        "read", "search", "links", "backlinks", "tasks", "tags",
        "aliases", "properties", "property:get", "property:list",
        "daily:read", "history:list", "history:read"
    ]

    private static let trustedReadOnlyPythonWrappers: Set<String> = [
        "obsidian_cli_tool.py"
    ]

    private static let trustedReadOnlyWrapperCommands: Set<String> = [
        "read", "summarize"
    ]

    private static func normalizedToolName(_ toolName: String?) -> String? {
        toolName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .nonEmpty
    }

    static func commandSafetyClass(for command: String) -> AssistantCommandSafetyClass {
        let normalized = normalize(command)
        guard !normalized.isEmpty else { return .mutatingOrUnknown }

        if containsDisallowedShellSyntax(normalized) {
            return .mutatingOrUnknown
        }

        if let stages = pipelineStages(from: normalized) {
            guard !stages.isEmpty else { return .mutatingOrUnknown }
            return stages.allSatisfy({ classifySimpleCommand($0) == .readOnly })
                ? .readOnly
                : .mutatingOrUnknown
        }

        return classifySimpleCommand(normalized)
    }

    static func shouldAutoApproveCommandRequest(
        mode: AssistantInteractionMode,
        command: String
    ) -> Bool {
        (mode == .conversational || mode == .plan) && commandSafetyClass(for: command) == .readOnly
    }

    static func activityTitle(forBlockedCommand command: String?) -> String {
        let collapsed = command?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            .nonEmpty
        return collapsed ?? "Command"
    }

    private static func classifySimpleCommand(_ normalizedCommand: String) -> AssistantCommandSafetyClass {
        let tokens = executableTokens(from: normalizedCommand)
        guard let executable = tokens.first else {
            return .mutatingOrUnknown
        }

        let firstTwo = tokens.prefix(2).joined(separator: " ")
        let firstThree = tokens.prefix(3).joined(separator: " ")

        switch executable {
        case "find":
            return isReadOnlyFindCommand(tokens) ? .readOnly : .mutatingOrUnknown
        case "plutil":
            return isReadOnlyPlutilCommand(tokens) ? .readOnly : .mutatingOrUnknown
        case let executable where simpleReadOnlyExecutables.contains(executable):
            return .readOnly
        case "sed":
            return firstTwo == "sed -n" ? .readOnly : .mutatingOrUnknown
        case "git":
            return gitReadOnlyCommands.contains(firstThree)
                || gitReadOnlyCommands.contains(firstTwo)
                ? .readOnly
                : .mutatingOrUnknown
        case "swift":
            switch firstTwo {
            case "swift build", "swift test":
                return .validation
            default:
                return .mutatingOrUnknown
            }
        case "xcodebuild":
            guard let action = tokens.dropFirst().first else {
                return .mutatingOrUnknown
            }
            return action == "build" || action == "test" ? .validation : .mutatingOrUnknown
        case "obsidian":
            return isTrustedDirectObsidianReadOnlyCommand(tokens) ? .readOnly : .mutatingOrUnknown
        case "python", "python3":
            return isTrustedReadOnlyPythonWrapper(tokens) ? .readOnly : .mutatingOrUnknown
        default:
            return .mutatingOrUnknown
        }
    }

    static func isAllowed(
        mode: AssistantInteractionMode,
        activityKind: AssistantActivityKind,
        command: String? = nil,
        toolName: String? = nil
    ) -> Bool {
        if mode == .agentic {
            return true
        }

        switch activityKind {
        case .commandExecution:
            let commandClass = commandSafetyClass(for: command ?? "")
            switch mode {
            case .conversational:
                return commandClass == .readOnly
            case .plan:
                // Plan mode allows read-only and validation (build/test) commands
                // but blocks mutating commands to keep the focus on planning.
                return commandClass == .readOnly || commandClass == .validation
            case .agentic:
                return true
            }
        case .webSearch:
            return true
        case .dynamicToolCall:
            switch mode {
            case .conversational, .plan:
                return normalizedToolName(toolName) != "computer_use"
            case .agentic:
                return true
            }
        case .fileChange, .browserAutomation:
            return false
        case .mcpToolCall:
            // Plan mode allows MCP tool calls for exploration (e.g. reading docs)
            return mode == .plan
        case .subagent:
            return false
        case .reasoning:
            return true
        case .other:
            return true
        }
    }

    static func blockedMessage(
        mode: AssistantInteractionMode,
        activityTitle: String? = nil,
        commandClass: AssistantCommandSafetyClass? = nil
    ) -> String {
        let normalizedTitle = activityTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let activityPhrase: String
        if let normalizedTitle, !normalizedTitle.isEmpty {
            activityPhrase = " before using \(normalizedTitle)"
        } else {
            activityPhrase = ""
        }

        switch mode {
        case .conversational:
            if normalizedTitle?.lowercased() == "computer use" || normalizedTitle?.lowercased() == "browser" {
                return "I stopped\(activityPhrase) because Chat mode cannot inspect the live screen or browser with computer-control tools. Chat mode can still analyze an attached image when the selected model supports image input. Switch to Agentic mode for live screen or browser inspection."
            }
            if commandClass == .validation {
                return "I stopped\(activityPhrase) because Chat mode can inspect files and search the web, but it cannot run build or test checks. Switch to Plan or Agentic mode if you want me to run checks."
            }
            return "I stopped\(activityPhrase) because Chat mode can inspect files, search the web, and read attached images when the selected model supports them, but it cannot make changes or use higher-risk tools. Switch to Agentic mode for execution."
        case .plan:
            if commandClass == .mutatingOrUnknown {
                return "I stopped\(activityPhrase) because Plan mode can explore, search, and run read-only or validation commands, but it cannot make changes. Switch to Agentic mode to execute."
            }
            return "I stopped\(activityPhrase) because Plan mode focuses on exploration and planning. Switch to Agentic mode to execute changes."
        case .agentic:
            return "Tool use is allowed in Agentic mode."
        }
    }

    private static func normalize(_ command: String) -> String {
        command
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private static func containsDisallowedShellSyntax(_ command: String) -> Bool {
        if command.contains("&&") || command.contains("||") || command.contains(";") {
            return true
        }
        if command.contains("|&") || command.hasSuffix("&") || command.contains(" & ") {
            return true
        }
        if command.contains(">") || command.contains("<") {
            return true
        }
        if command.contains(" tee ") || command.contains("$(") {
            return true
        }
        return command.contains("`")
    }

    private static func pipelineStages(from command: String) -> [String]? {
        guard command.contains("|") else { return nil }
        let stages = command
            .split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return stages.isEmpty ? nil : stages
    }

    private static func executableTokens(from command: String) -> [String] {
        var tokens = command.split(separator: " ").map(String.init)
        while let first = tokens.first, isEnvironmentAssignment(first) {
            tokens.removeFirst()
        }

        if tokens.first == "env" {
            tokens.removeFirst()
            while let first = tokens.first, isEnvironmentAssignment(first) {
                tokens.removeFirst()
            }
        }

        return tokens
    }

    private static func isEnvironmentAssignment(_ token: String) -> Bool {
        token.range(
            of: #"^[a-z_][a-z0-9_]*=.*$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func isTrustedDirectObsidianReadOnlyCommand(_ tokens: [String]) -> Bool {
        guard let command = tokens.dropFirst().first else {
            return false
        }
        return directObsidianReadOnlyCommands.contains(command)
    }

    private static func isReadOnlyFindCommand(_ tokens: [String]) -> Bool {
        let unsafeFlags: Set<String> = [
            "-delete", "-exec", "-execdir", "-ok", "-okdir",
            "-fprint", "-fprint0", "-fprintf", "-fls"
        ]

        for token in tokens.dropFirst() {
            if unsafeFlags.contains(token) {
                return false
            }
        }
        return true
    }

    private static func isReadOnlyPlutilCommand(_ tokens: [String]) -> Bool {
        let arguments = Array(tokens.dropFirst())
        guard let firstArgument = arguments.first else {
            return false
        }

        if arguments.contains("-replace")
            || arguments.contains("-insert")
            || arguments.contains("-remove")
            || arguments.contains("-create") {
            return false
        }

        return firstArgument == "-p" || firstArgument == "-lint"
    }

    private static func isTrustedReadOnlyPythonWrapper(_ tokens: [String]) -> Bool {
        guard tokens.count >= 3 else { return false }
        guard trustedReadOnlyPythonWrappers.contains(where: { tokens[1].hasSuffix($0) }) else {
            return false
        }

        let subcommand = tokens.dropFirst(2).first { !$0.hasPrefix("-") }
        guard let subcommand else { return false }
        return trustedReadOnlyWrapperCommands.contains(subcommand)
    }
}
