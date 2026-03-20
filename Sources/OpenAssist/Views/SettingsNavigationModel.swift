import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case overview
    case assistant
    case voiceDictation
    case automationRemote
    case appPermissions

    var id: Self { self }

    var title: String {
        switch self {
        case .overview:
            return "Overview"
        case .assistant:
            return "Assistant"
        case .voiceDictation:
            return "Voice & Dictation"
        case .automationRemote:
            return "Automation & Remote"
        case .appPermissions:
            return "App & Permissions"
        }
    }

    var subtitle: String {
        switch self {
        case .overview:
            return "See what Open Assist helps with and where to start."
        case .assistant:
            return "Everyday AI controls, provider status, and AI Studio entry points."
        case .voiceDictation:
            return "Dictation setup, speech engines, shortcuts, and text cleanup."
        case .automationRemote:
            return "Browser control, local API alerts, and Telegram remote access."
        case .appPermissions:
            return "Appearance, permissions, app info, diagnostics, and uninstall."
        }
    }

    var iconName: String {
        switch self {
        case .overview:
            return "square.grid.2x2"
        case .assistant:
            return "brain.head.profile"
        case .voiceDictation:
            return "waveform.and.mic"
        case .automationRemote:
            return "point.3.connected.trianglepath.dotted"
        case .appPermissions:
            return "gearshape.2"
        }
    }

    var tint: Color {
        switch self {
        case .overview:
            return Color(red: 0.32, green: 0.62, blue: 0.94)
        case .assistant:
            return Color(red: 0.45, green: 0.56, blue: 0.92)
        case .voiceDictation:
            return Color(red: 0.27, green: 0.72, blue: 0.54)
        case .automationRemote:
            return Color(red: 0.23, green: 0.67, blue: 0.76)
        case .appPermissions:
            return Color(red: 0.84, green: 0.58, blue: 0.24)
        }
    }

    var searchTerms: [String] {
        switch self {
        case .overview:
            return ["overview", "start", "ask", "speak", "act", "what is open assist", "setup summary"]
        case .assistant:
            return ["assistant", "ai", "prompt", "rewrite", "memory", "provider", "oauth", "api key", "openai", "anthropic", "google", "gemini", "studio", "agent shortcut"]
        case .voiceDictation:
            return ["voice", "dictation", "speech", "shortcut", "hold to talk", "continuous", "microphone", "whisper", "model", "cleanup", "correction", "phrases"]
        case .automationRemote:
            return ["automation", "remote", "browser", "telegram", "claude", "codex", "notifications", "api", "apple events", "local api", "browser profile"]
        case .appPermissions:
            return ["app", "permissions", "appearance", "theme", "version", "updates", "diagnostics", "crash logs", "uninstall"]
        }
    }
}

enum SettingsAutomationPage: String, CaseIterable, Identifiable {
    case overview
    case browserAndApps
    case notificationsAndAPI
    case telegramRemote

    var id: Self { self }

    var title: String {
        switch self {
        case .overview:
            return "Overview"
        case .browserAndApps:
            return "Browser & App Control"
        case .notificationsAndAPI:
            return "Notifications & Local API"
        case .telegramRemote:
            return "Telegram Remote"
        }
    }
}

struct SettingsNavigationTarget: Equatable {
    let section: SettingsSection
    let automationPage: SettingsAutomationPage?

    init(section: SettingsSection, automationPage: SettingsAutomationPage? = nil) {
        self.section = section
        self.automationPage = automationPage
    }
}

struct SettingSearchEntry: Identifiable, Equatable {
    let destination: SettingsNavigationTarget
    let title: String
    let detail: String
    let keywords: [String]

    var section: SettingsSection {
        destination.section
    }

    var id: String {
        let automationKey = destination.automationPage?.rawValue ?? "root"
        return "\(section.rawValue)-\(automationKey)-\(title)"
    }
}

enum SettingsNavigationModel {
    static let searchEntries: [SettingSearchEntry] = [
        .init(
            destination: SettingsNavigationTarget(section: .overview),
            title: "Ask, Speak, and Act overview",
            detail: "See the main ways Open Assist helps you on your Mac",
            keywords: ["overview", "ask", "speak", "act", "what is the app for", "start"]
        ),
        .init(
            destination: SettingsNavigationTarget(section: .assistant),
            title: "AI prompt correction",
            detail: "Enable or disable everyday AI writing help",
            keywords: ["prompt", "rewrite", "toggle", "enable", "ai"]
        ),
        .init(
            destination: SettingsNavigationTarget(section: .assistant),
            title: "Auto-insert high-confidence suggestions",
            detail: "Insert AI suggestions automatically when confidence is high",
            keywords: ["auto", "insert", "confidence", "rewrite", "preview"]
        ),
        .init(
            destination: SettingsNavigationTarget(section: .assistant),
            title: "Markdown suggestion conversion",
            detail: "Always convert AI suggestions to Markdown before insertion",
            keywords: ["markdown", "format", "rewrite", "insert", "assistant"]
        ),
        .init(
            destination: SettingsNavigationTarget(section: .assistant),
            title: "Provider connection summary",
            detail: "See which AI providers are ready",
            keywords: ["provider", "oauth", "api key", "openai", "anthropic", "google", "gemini", "connection"]
        ),
        .init(
            destination: SettingsNavigationTarget(section: .assistant),
            title: "AI Studio",
            detail: "Open advanced provider, model, and memory controls",
            keywords: ["ai", "studio", "providers", "models", "memory", "advanced"]
        ),
        .init(
            destination: SettingsNavigationTarget(section: .assistant),
            title: "Agent shortcut",
            detail: "Hold to speak and paste into the assistant box",
            keywords: ["assistant", "agent", "voice", "shortcut", "keyboard", "hold", "paste"]
        ),
        .init(
            destination: SettingsNavigationTarget(section: .voiceDictation),
            title: "Microphone device picker",
            detail: "Choose a microphone or auto-detect one",
            keywords: ["microphone", "input", "device", "picker", "auto"]
        ),
        .init(
            destination: SettingsNavigationTarget(section: .voiceDictation),
            title: "Transcription engine",
            detail: "Switch between Apple Speech, whisper.cpp, and cloud providers",
            keywords: ["engine", "whisper", "apple", "cloud", "openai", "groq", "deepgram", "gemini", "recognition"]
        ),
        .init(
            destination: SettingsNavigationTarget(section: .voiceDictation),
            title: "Dictation output",
            detail: "Control clipboard behavior for inserted voice results",
            keywords: ["clipboard", "copy", "output", "dictation"]
        ),
        .init(
            destination: SettingsNavigationTarget(section: .voiceDictation),
            title: "Dictation sounds",
            detail: "Choose start, stop, processing, and pasted sound cues",
            keywords: ["sound", "start", "listening", "feedback", "processing", "stop", "pasted"]
        ),
        .init(
            destination: SettingsNavigationTarget(section: .voiceDictation),
            title: "Hold-to-talk shortcut",
            detail: "Set keys for press-and-hold dictation",
            keywords: ["hold", "shortcut", "keyboard", "voice"]
        ),
        .init(
            destination: SettingsNavigationTarget(section: .voiceDictation),
            title: "Continuous toggle shortcut",
            detail: "Set keys for start and stop continuous dictation",
            keywords: ["continuous", "toggle", "shortcut", "keyboard"]
        ),
        .init(
            destination: SettingsNavigationTarget(section: .voiceDictation),
            title: "Paste last transcript",
            detail: "Reserved shortcut: Option-Command-V",
            keywords: ["paste", "last transcript", "reserved", "history"]
        ),
        .init(
            destination: SettingsNavigationTarget(section: .voiceDictation),
            title: "Finalize delay",
            detail: "Control speed versus stability before insertion",
            keywords: ["delay", "finalize", "timing"]
        ),
        .init(
            destination: SettingsNavigationTarget(section: .voiceDictation),
            title: "Cleanup mode",
            detail: "Light or aggressive text cleanup",
            keywords: ["cleanup", "mode", "text quality"]
        ),
        .init(
            destination: SettingsNavigationTarget(section: .voiceDictation),
            title: "Custom phrases",
            detail: "Add names, acronyms, and domain language",
            keywords: ["phrases", "vocabulary", "context"]
        ),
        .init(
            destination: SettingsNavigationTarget(section: .voiceDictation),
            title: "Whisper model library",
            detail: "Download and manage whisper.cpp models",
            keywords: ["model", "download", "whisper", "tiny", "base", "small", "medium", "large"]
        ),
        .init(
            destination: SettingsNavigationTarget(section: .voiceDictation),
            title: "Whisper Core ML",
            detail: "Use Core ML encoder when available",
            keywords: ["core ml", "ane", "whisper", "speed"]
        ),
        .init(
            destination: SettingsNavigationTarget(section: .voiceDictation),
            title: "Adaptive corrections",
            detail: "Learn from your quick word and phrase fixes",
            keywords: ["adaptive", "learned", "corrections", "backspace"]
        ),
        .init(
            destination: SettingsNavigationTarget(section: .voiceDictation),
            title: "Learned corrections list",
            detail: "View, remove, or clear saved corrections",
            keywords: ["learned", "list", "remove", "clear"]
        ),
        .init(
            destination: SettingsNavigationTarget(section: .automationRemote, automationPage: .browserAndApps),
            title: "Automation permissions",
            detail: "Review Apple Events and Full Disk Access for browser and app actions",
            keywords: ["automation", "apple events", "full disk", "browser", "permissions"]
        ),
        .init(
            destination: SettingsNavigationTarget(section: .automationRemote, automationPage: .browserAndApps),
            title: "Browser profile",
            detail: "Choose the Chrome, Brave, or Edge profile Open Assist should reuse",
            keywords: ["browser", "profile", "chrome", "brave", "edge", "session"]
        ),
        .init(
            destination: SettingsNavigationTarget(section: .automationRemote, automationPage: .browserAndApps),
            title: "Helper status",
            detail: "See local automation helper readiness and setup issues",
            keywords: ["helper", "status", "issues", "readiness"]
        ),
        .init(
            destination: SettingsNavigationTarget(section: .automationRemote, automationPage: .browserAndApps),
            title: "Supported direct app actions",
            detail: "See Finder, Terminal, Calendar, System Settings, Reminders, Contacts, Notes, and Messages actions",
            keywords: ["finder", "terminal", "calendar", "system settings", "app action", "messages", "notes", "contacts", "reminders"]
        ),
        .init(
            destination: SettingsNavigationTarget(section: .automationRemote, automationPage: .browserAndApps),
            title: "Approval behavior",
            detail: "Understand session approvals and high-risk confirmation rules",
            keywords: ["approval", "allow", "session", "confirmation", "risky"]
        ),
        .init(
            destination: SettingsNavigationTarget(section: .automationRemote, automationPage: .notificationsAndAPI),
            title: "Automation notifications",
            detail: "Open the page for Claude Code, Codex CLI, and Codex Cloud alerts",
            keywords: ["automation", "notifications", "sources", "codex", "claude"]
        ),
        .init(
            destination: SettingsNavigationTarget(section: .automationRemote, automationPage: .notificationsAndAPI),
            title: "Enable automation API",
            detail: "Run a localhost API for Claude Code and Codex CLI",
            keywords: ["automation", "api", "localhost", "server", "claude", "codex"]
        ),
        .init(
            destination: SettingsNavigationTarget(section: .automationRemote, automationPage: .notificationsAndAPI),
            title: "Automation API token",
            detail: "Copy or rotate the local bearer token",
            keywords: ["token", "bearer", "auth", "copy", "rotate"]
        ),
        .init(
            destination: SettingsNavigationTarget(section: .automationRemote, automationPage: .notificationsAndAPI),
            title: "Claude hooks",
            detail: "Install Notification and Stop hooks into Claude Code",
            keywords: ["claude", "hook", "notification", "stop", "subagent"]
        ),
        .init(
            destination: SettingsNavigationTarget(section: .automationRemote, automationPage: .notificationsAndAPI),
            title: "Codex CLI notify config",
            detail: "Copy the Codex CLI notify snippet for ~/.codex/config.toml",
            keywords: ["codex", "notify", "config", "toml", "cloud"]
        ),
        .init(
            destination: SettingsNavigationTarget(section: .automationRemote, automationPage: .notificationsAndAPI),
            title: "Codex Cloud beta",
            detail: "Watch local codex cloud tasks and alert when they are ready or fail",
            keywords: ["codex", "cloud", "beta", "polling", "ready", "failed"]
        ),
        .init(
            destination: SettingsNavigationTarget(section: .automationRemote, automationPage: .notificationsAndAPI),
            title: "Desktop notification permission",
            detail: "Allow desktop notifications for local API alerts",
            keywords: ["notification", "permission", "desktop", "grant"]
        ),
        .init(
            destination: SettingsNavigationTarget(section: .automationRemote, automationPage: .telegramRemote),
            title: "Telegram remote",
            detail: "Control the selected Open Assist session from a private Telegram bot chat",
            keywords: ["telegram", "remote", "bot", "chat", "session"]
        ),
        .init(
            destination: SettingsNavigationTarget(section: .automationRemote, automationPage: .telegramRemote),
            title: "Telegram bot token",
            detail: "Paste, copy, test, or clear your Telegram bot token",
            keywords: ["telegram", "botfather", "token", "paste", "copy"]
        ),
        .init(
            destination: SettingsNavigationTarget(section: .automationRemote, automationPage: .telegramRemote),
            title: "Telegram pairing",
            detail: "Approve or forget the private Telegram chat that can control Open Assist",
            keywords: ["telegram", "pairing", "approve", "private", "chat"]
        ),
        .init(
            destination: SettingsNavigationTarget(section: .automationRemote, automationPage: .telegramRemote),
            title: "Telegram setup steps",
            detail: "Follow the built-in BotFather and /start setup guide",
            keywords: ["telegram", "setup", "steps", "botfather", "start"]
        ),
        .init(
            destination: SettingsNavigationTarget(section: .automationRemote, automationPage: .telegramRemote),
            title: "Telegram session switching",
            detail: "Switch sessions without mixing messages from different chats",
            keywords: ["telegram", "switch", "session", "messages", "mixed"]
        ),
        .init(
            destination: SettingsNavigationTarget(section: .appPermissions),
            title: "Appearance",
            detail: "Choose theme, window style, and waveform look",
            keywords: ["appearance", "theme", "style", "waveform", "color"]
        ),
        .init(
            destination: SettingsNavigationTarget(section: .appPermissions),
            title: "Permission overview",
            detail: "See accessibility, microphone, speech, and automation status",
            keywords: ["permissions", "accessibility", "microphone", "speech", "automation"]
        ),
        .init(
            destination: SettingsNavigationTarget(section: .appPermissions),
            title: "App info",
            detail: "See the version and check for updates",
            keywords: ["version", "updates", "app info", "build"]
        ),
        .init(
            destination: SettingsNavigationTarget(section: .appPermissions),
            title: "Crash logs",
            detail: "Open existing crash logs in Finder",
            keywords: ["crash", "logs", "diagnostics"]
        ),
        .init(
            destination: SettingsNavigationTarget(section: .appPermissions),
            title: "Uninstall Open Assist",
            detail: "Remove the app and clear local settings",
            keywords: ["uninstall", "remove", "reset"]
        )
    ]

    static func filteredSearchEntries(for query: String) -> [SettingSearchEntry] {
        let normalized = normalizedSearchQuery(query)
        guard !normalized.isEmpty else { return [] }
        return searchEntries.filter { entry in
            let haystack = ([entry.title, entry.detail] + entry.keywords).joined(separator: " ").lowercased()
            return haystack.contains(normalized)
        }
    }

    static func filteredSections(for query: String) -> [SettingsSection] {
        let normalized = normalizedSearchQuery(query)
        guard !normalized.isEmpty else {
            return SettingsSection.allCases
        }

        let fromSectionTerms = SettingsSection.allCases.filter { section in
            let sectionHaystack = ([section.title, section.subtitle] + section.searchTerms)
                .joined(separator: " ")
                .lowercased()
            return sectionHaystack.contains(normalized)
        }
        let fromEntries = Set(filteredSearchEntries(for: normalized).map(\.section))
        return SettingsSection.allCases.filter { section in
            fromSectionTerms.contains(section) || fromEntries.contains(section)
        }
    }

    static func normalizedSearchQuery(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
