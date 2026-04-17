import Foundation

enum AssistantSlashCommandBehavior: String, Codable, Sendable {
    case insertText
    case localMode
}

enum AssistantSlashCommandTrackingMode: String, Codable, Sendable {
    case localMode
    case work
    case state
    case ignored

    var isTrackable: Bool {
        switch self {
        case .localMode, .ignored:
            return false
        case .work, .state:
            return true
        }
    }
}

struct AssistantSlashCommandDescriptor: Equatable, Sendable, Identifiable {
    let id: String
    let label: String
    let subtitle: String
    let groupID: String
    let groupLabel: String
    let groupTone: String
    let groupOrder: Int
    let searchKeywords: [String]
    let insertText: String
    let behavior: AssistantSlashCommandBehavior
    let trackingMode: AssistantSlashCommandTrackingMode
    let isMenuVisible: Bool
    let localMode: String?

    var normalizedSlashToken: String {
        label
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

struct AssistantSubmittedSlashCommand: Equatable, Sendable {
    let descriptor: AssistantSlashCommandDescriptor
    let submittedText: String
    let remainderText: String?

    var id: String { descriptor.id }
    var label: String { descriptor.label }
    var behavior: AssistantSlashCommandBehavior { descriptor.behavior }
    var trackingMode: AssistantSlashCommandTrackingMode { descriptor.trackingMode }

    var isTrackable: Bool {
        trackingMode.isTrackable
    }

    var commandOnlyText: String {
        descriptor.label
    }
}

enum AssistantSlashCommandCatalog {
    private static let localComposerCommands: [AssistantSlashCommandDescriptor] = [
        AssistantSlashCommandDescriptor(
            id: "note",
            label: "/note",
            subtitle: "Turn on sticky Note Mode for this chat.",
            groupID: "mode",
            groupLabel: "Modes",
            groupTone: "mode",
            groupOrder: 10,
            searchKeywords: ["notes", "project notes", "thread notes", "assistant notes"],
            insertText: "/note",
            behavior: .localMode,
            trackingMode: .localMode,
            isMenuVisible: true,
            localMode: "note"
        ),
        AssistantSlashCommandDescriptor(
            id: "chat",
            label: "/chat",
            subtitle: "Turn Note Mode off and go back to normal chat.",
            groupID: "mode",
            groupLabel: "Modes",
            groupTone: "mode",
            groupOrder: 10,
            searchKeywords: ["normal chat", "default mode", "general"],
            insertText: "/chat",
            behavior: .localMode,
            trackingMode: .localMode,
            isMenuVisible: true,
            localMode: "chat"
        ),
    ]

    private static let copilotComposerCommands: [AssistantSlashCommandDescriptor] = [
        copilotCommand("init", "Generate Copilot instructions for this workspace.", .state, visible: true, keywords: ["instructions", "setup"]),
        copilotCommand("agent", "Pick or switch the Copilot agent for this chat.", .state, visible: true, keywords: ["custom agent", "persona"]),
        copilotCommand("skills", "Manage Copilot skills for this session.", .state, visible: true, keywords: ["skill", "abilities"]),
        copilotCommand("mcp", "Manage MCP servers and tools.", .state, visible: true, keywords: ["mcp servers", "tools"]),
        copilotCommand("plugin", "Manage Copilot plugins.", .state, visible: true, keywords: ["plugins", "extensions"]),
        copilotCommand("model", "Change the model for this Copilot session.", .state, visible: true, keywords: ["switch model", "gpt"]),
        copilotCommand("delegate", "Delegate work to Copilot in the background.", .work, visible: true, keywords: ["background work", "async"]),
        copilotCommand("fleet", "Run several Copilot agents in parallel.", .work, visible: true, keywords: ["parallel agents", "background agents"]),
        copilotCommand("tasks", "View and manage Copilot background tasks.", .work, visible: true, keywords: ["background tasks", "agents"]),
        copilotCommand("ide", "Connect or switch IDE integration.", .state, visible: true, keywords: ["editor", "vscode"]),
        copilotCommand("diff", "Review current changes in the repo.", .state, visible: true, keywords: ["git diff", "changes"]),
        copilotCommand("pr", "Open pull request review or PR-related work.", .work, visible: true, keywords: ["pull request", "review pr"]),
        copilotCommand("review", "Ask Copilot to review code or changes.", .work, visible: true, keywords: ["code review", "inspect"]),
        copilotCommand("lsp", "Manage language server tools.", .state, visible: true, keywords: ["language server", "code intelligence"]),
        copilotCommand("terminal-setup", "Configure terminal behavior for Copilot.", .state, visible: true, keywords: ["shell setup", "terminal"]),
        copilotCommand("cwd", "Change the current working directory for the session.", .state, visible: true, keywords: ["working directory", "path"]),
        copilotCommand("resume", "Resume another Copilot session.", .state, visible: true, keywords: ["restore session", "open session"]),
        copilotCommand("rename", "Rename the current Copilot session.", .state, visible: true, keywords: ["session name", "title"]),
        copilotCommand("session", "Inspect or manage the current session.", .state, visible: true, keywords: ["session info", "thread"]),
        copilotCommand("compact", "Compact the conversation history.", .state, visible: true, keywords: ["compaction", "history"]),
        copilotCommand("share", "Share this Copilot session.", .state, visible: true, keywords: ["share session", "link"]),
        copilotCommand("remote", "Manage remote execution or remote sessions.", .state, visible: true, keywords: ["remote", "ssh"]),
        copilotCommand("copy", "Copy the last useful output.", .state, visible: true, keywords: ["clipboard", "copy output"]),
        copilotCommand("experimental", "Toggle experimental Copilot features.", .state, visible: true, keywords: ["feature flags", "labs"]),
        copilotCommand("instructions", "View or toggle active instruction files.", .state, visible: true, keywords: ["custom instructions", "rules"]),
        copilotCommand("streamer-mode", "Adjust streamer mode privacy settings.", .state, visible: true, keywords: ["privacy", "streaming"]),
        copilotCommand("plan", "Ask Copilot to plan the work.", .work, visible: true, keywords: ["plan work", "steps"]),
        copilotCommand("research", "Ask Copilot to investigate before acting.", .work, visible: true, keywords: ["investigate", "analyze"]),
        copilotCommand("user", "Open user or account options.", .state, visible: true, keywords: ["account", "profile"]),
        copilotCommand("allow-all", "Approve all tool use for the session.", .state, visible: false, keywords: ["approve all", "yolo"]),
        copilotCommand("add-dir", "Add another workspace directory to the session.", .state, visible: false, keywords: ["workspace", "directory"]),
        copilotCommand("reset-allowed-tools", "Clear saved tool approvals for the session.", .state, visible: false, keywords: ["permissions", "approvals"]),
        copilotCommand("login", "Sign in to Copilot.", .state, visible: false, keywords: ["sign in", "auth"]),
        copilotCommand("logout", "Sign out of Copilot.", .state, visible: false, keywords: ["sign out", "auth"]),
        copilotCommand("new", "Start a new Copilot session.", .state, visible: false, keywords: ["new session", "thread"]),
        copilotCommand("clear", "Clear the current Copilot session.", .state, visible: false, keywords: ["reset session", "clear chat"]),
        copilotCommand("restart", "Restart the current Copilot session.", .state, visible: false, keywords: ["restart session", "reload"]),
        copilotCommand("rewind", "Rewind to an earlier point in the session.", .state, visible: false, keywords: ["undo history", "checkpoint"]),
        copilotCommand("undo", "Undo the last session action.", .state, visible: false, keywords: ["undo", "rollback"]),
        copilotCommand("theme", "Change the Copilot CLI theme.", .state, visible: false, keywords: ["appearance", "colors"]),
        copilotCommand("update", "Check for Copilot CLI updates.", .state, visible: false, keywords: ["upgrade", "version"]),
        copilotCommand("exit", "Exit the Copilot CLI session.", .state, visible: false, keywords: ["quit", "close"]),
        copilotCommand("quit", "Quit the Copilot CLI session.", .state, visible: false, keywords: ["exit", "close"]),
        copilotCommand("help", "Show Copilot help.", .ignored, visible: false, keywords: ["help", "docs"]),
        copilotCommand("changelog", "Show Copilot release notes.", .ignored, visible: false, keywords: ["release notes", "updates"]),
        copilotCommand("feedback", "Send feedback about Copilot CLI.", .ignored, visible: false, keywords: ["feedback", "report"]),
        copilotCommand("context", "Inspect session context usage.", .ignored, visible: false, keywords: ["context window", "tokens"]),
        copilotCommand("usage", "Inspect usage and quota details.", .ignored, visible: false, keywords: ["quota", "usage"]),
        copilotCommand("env", "Inspect environment details.", .ignored, visible: false, keywords: ["environment", "variables"]),
        copilotCommand("version", "Show the Copilot CLI version.", .ignored, visible: false, keywords: ["version", "about"]),
        copilotCommand("list-dirs", "List attached workspace directories.", .ignored, visible: false, keywords: ["directories", "workspace list"]),
    ]

    static func composerCommands(
        for backend: AssistantRuntimeBackend
    ) -> [AssistantSlashCommandDescriptor] {
        let visibleCopilotCommands =
            backend == .copilot
            ? copilotComposerCommands.filter(\.isMenuVisible)
            : []
        return visibleCopilotCommands + localComposerCommands
    }

    static func detectLeadingCommand(
        in text: String,
        backend: AssistantRuntimeBackend
    ) -> AssistantSubmittedSlashCommand? {
        let trimmedLeading = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedLeading.hasPrefix("/") else { return nil }

        let commands = backend == .copilot
            ? copilotComposerCommands + localComposerCommands
            : localComposerCommands

        guard let match = trimmedLeading.range(
            of: #"^/([a-z][a-z0-9-]*)(?=$|\s)"#,
            options: [.regularExpression, .caseInsensitive]
        ) else {
            return nil
        }

        let token = String(trimmedLeading[match]).lowercased()
        guard let descriptor = commands.first(where: { $0.normalizedSlashToken == token }) else {
            return nil
        }

        let remainder = trimmedLeading[match.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty

        return AssistantSubmittedSlashCommand(
            descriptor: descriptor,
            submittedText: remainder.map { "\(token) \($0)" } ?? token,
            remainderText: remainder
        )
    }

    private static func copilotCommand(
        _ id: String,
        _ subtitle: String,
        _ trackingMode: AssistantSlashCommandTrackingMode,
        visible: Bool,
        keywords: [String] = []
    ) -> AssistantSlashCommandDescriptor {
        AssistantSlashCommandDescriptor(
            id: id,
            label: "/\(id)",
            subtitle: subtitle,
            groupID: "copilot",
            groupLabel: "Copilot",
            groupTone: "copilot",
            groupOrder: 0,
            searchKeywords: keywords,
            insertText: "/\(id)",
            behavior: .insertText,
            trackingMode: trackingMode,
            isMenuVisible: visible,
            localMode: nil
        )
    }
}
