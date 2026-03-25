import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable, Sendable {
    case gettingStarted
    case dailyUse
    case voiceDictation
    case browserAppControl
    case permissionsPrivacy
    case advanced

    var id: Self { self }

    static let sidebarSections: [SettingsSection] = Self.allCases

    var title: String {
        switch self {
        case .gettingStarted:
            return "Getting Started"
        case .dailyUse:
            return "Daily Use"
        case .voiceDictation:
            return "Voice & Dictation"
        case .browserAppControl:
            return "Browser & App Control"
        case .permissionsPrivacy:
            return "Permissions & Privacy"
        case .advanced:
            return "Advanced"
        }
    }

    var subtitle: String {
        switch self {
        case .gettingStarted:
            return "A simple setup home with the most important next steps."
        case .dailyUse:
            return "The controls most people use often, with clear shortcuts to deeper setup."
        case .voiceDictation:
            return "Microphone, dictation, shortcuts, Whisper, and correction controls."
        case .browserAppControl:
            return "Browser reuse, direct app actions, computer use, and approval behavior."
        case .permissionsPrivacy:
            return "See what access is granted and open the right macOS privacy screens."
        case .advanced:
            return "AI Studio, provider status, integrations, diagnostics, and app maintenance."
        }
    }

    var iconName: String {
        switch self {
        case .gettingStarted:
            return "flag.checkered.2.crossed"
        case .dailyUse:
            return "sparkles"
        case .voiceDictation:
            return "waveform.and.mic"
        case .browserAppControl:
            return "point.3.connected.trianglepath.dotted"
        case .permissionsPrivacy:
            return "hand.raised.fill"
        case .advanced:
            return "slider.horizontal.3"
        }
    }

    var tint: Color {
        switch self {
        case .gettingStarted:
            return Color(red: 0.33, green: 0.63, blue: 0.95)
        case .dailyUse:
            return Color(red: 0.31, green: 0.58, blue: 0.95)
        case .voiceDictation:
            return Color(red: 0.27, green: 0.72, blue: 0.54)
        case .browserAppControl:
            return Color(red: 0.23, green: 0.67, blue: 0.76)
        case .permissionsPrivacy:
            return Color(red: 0.84, green: 0.58, blue: 0.24)
        case .advanced:
            return Color(red: 0.47, green: 0.55, blue: 0.92)
        }
    }

    var searchTerms: [String] {
        switch self {
        case .gettingStarted:
            return ["getting started", "setup", "first run", "onboarding", "start", "checklist"]
        case .dailyUse:
            return ["daily", "assistant", "clipboard", "appearance", "sounds", "common tasks"]
        case .voiceDictation:
            return ["voice", "dictation", "speech", "shortcut", "hold to talk", "microphone", "whisper", "cleanup", "correction"]
        case .browserAppControl:
            return ["browser", "automation", "computer use", "app action", "screen recording", "apple events", "profile", "finder", "terminal"]
        case .permissionsPrivacy:
            return ["permissions", "privacy", "accessibility", "microphone", "speech recognition", "full disk"]
        case .advanced:
            return ["advanced", "ai studio", "providers", "models", "integrations", "telegram", "diagnostics", "uninstall"]
        }
    }
}

enum SettingsAdvancedPage: String, CaseIterable, Identifiable, Sendable {
    case overview
    case automationNotifications
    case telegramRemote

    var id: Self { self }
}

struct SettingsRoute: Equatable, Sendable {
    let section: SettingsSection
    let cardID: String?
    let advancedPage: SettingsAdvancedPage?
    let opensAIStudio: Bool

    init(
        section: SettingsSection,
        cardID: String? = nil,
        advancedPage: SettingsAdvancedPage? = nil,
        opensAIStudio: Bool = false
    ) {
        self.section = section
        self.cardID = cardID
        self.advancedPage = advancedPage
        self.opensAIStudio = opensAIStudio
    }

    static let gettingStartedHome = SettingsRoute(section: .gettingStarted, cardID: "gettingStarted.checklist")
}

enum GettingStartedStepStatus: Equatable, Sendable {
    case notStarted
    case needsAttention
    case ready

    var label: String {
        switch self {
        case .notStarted:
            return "Not started"
        case .needsAttention:
            return "Needs attention"
        case .ready:
            return "Ready"
        }
    }

    var tint: Color {
        switch self {
        case .notStarted:
            return .orange
        case .needsAttention:
            return .orange
        case .ready:
            return .green
        }
    }
}

struct GettingStartedStep: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let detail: String
    let status: GettingStartedStepStatus
    let primaryActionTitle: String
    let destination: SettingsRoute
}

struct SettingSearchEntry: Identifiable, Equatable, Sendable {
    let destination: SettingsRoute
    let title: String
    let detail: String
    let keywords: [String]

    var section: SettingsSection {
        destination.section
    }

    var id: String {
        let card = destination.cardID ?? "root"
        let advancedPage = destination.advancedPage?.rawValue ?? "overview"
        return "\(section.rawValue)-\(advancedPage)-\(card)-\(title)"
    }
}

enum SettingsNavigationModel {
    static let aiStudioDescription = "Advanced AI providers, models, memory, and local AI"

    static let searchEntries: [SettingSearchEntry] = [
        .init(
            destination: .gettingStartedHome,
            title: "Getting started",
            detail: "Open the setup checklist with the most important next steps",
            keywords: ["getting started", "setup", "start", "onboarding", "first run", "checklist"]
        ),
        .init(
            destination: SettingsRoute(section: .dailyUse, cardID: "daily.tasks"),
            title: "Daily task shortcuts",
            detail: "Jump to common tasks like assistant, voice, browser control, and AI setup",
            keywords: ["daily", "task", "shortcut", "assistant", "voice", "browser", "common"]
        ),
        .init(
            destination: SettingsRoute(section: .dailyUse, cardID: "daily.assistant"),
            title: "Assistant basics",
            detail: "Everyday assistant writing and suggestion controls",
            keywords: ["assistant", "rewrite", "prompt", "auto insert", "markdown"]
        ),
        .init(
            destination: SettingsRoute(section: .dailyUse, cardID: "daily.output"),
            title: "Dictation output",
            detail: "Control clipboard behavior for inserted voice results",
            keywords: ["clipboard", "copy", "output", "dictation"]
        ),
        .init(
            destination: SettingsRoute(section: .dailyUse, cardID: "daily.sounds"),
            title: "Dictation sounds",
            detail: "Choose start, stop, processing, and pasted sound cues",
            keywords: ["sound", "start", "listening", "feedback", "processing", "stop", "pasted"]
        ),
        .init(
            destination: SettingsRoute(section: .dailyUse, cardID: "daily.appearance"),
            title: "Appearance",
            detail: "Choose theme, window style, and waveform look",
            keywords: ["appearance", "theme", "style", "waveform", "color"]
        ),
        .init(
            destination: SettingsRoute(section: .voiceDictation, cardID: "voice.tasks"),
            title: "Voice setup",
            detail: "Open the voice and dictation quick-start area",
            keywords: ["voice", "dictation", "test dictation", "microphone", "shortcut"]
        ),
        .init(
            destination: SettingsRoute(section: .voiceDictation, cardID: "shortcuts.agentShortcut"),
            title: "Agent shortcut",
            detail: "Hold to speak and paste into the assistant box",
            keywords: ["assistant", "agent", "voice", "shortcut", "keyboard", "hold", "paste"]
        ),
        .init(
            destination: SettingsRoute(section: .voiceDictation, cardID: "shortcuts.holdToTalk"),
            title: "Hold-to-talk shortcut",
            detail: "Set keys for press-and-hold dictation",
            keywords: ["hold", "shortcut", "keyboard", "voice"]
        ),
        .init(
            destination: SettingsRoute(section: .voiceDictation, cardID: "shortcuts.continuousToggle"),
            title: "Continuous toggle shortcut",
            detail: "Set keys for start and stop continuous dictation",
            keywords: ["continuous", "toggle", "shortcut", "keyboard"]
        ),
        .init(
            destination: SettingsRoute(section: .voiceDictation, cardID: "speech.inputDevice"),
            title: "Microphone device picker",
            detail: "Choose a microphone or auto-detect one",
            keywords: ["microphone", "input", "device", "picker", "auto"]
        ),
        .init(
            destination: SettingsRoute(section: .voiceDictation, cardID: "speech.transcriptionEngine"),
            title: "Transcription engine",
            detail: "Switch between Apple Speech, whisper.cpp, and cloud providers",
            keywords: ["engine", "whisper", "apple", "cloud", "openai", "groq", "deepgram", "gemini", "recognition"]
        ),
        .init(
            destination: SettingsRoute(section: .voiceDictation, cardID: "speech.modelLibrary"),
            title: "Whisper model library",
            detail: "Download and manage whisper.cpp models",
            keywords: ["model", "download", "whisper", "tiny", "base", "small", "medium", "large"]
        ),
        .init(
            destination: SettingsRoute(section: .voiceDictation, cardID: "speech.textQuality"),
            title: "Text quality",
            detail: "Finalize delay, cleanup mode, and custom phrases",
            keywords: ["cleanup", "mode", "text quality", "finalize", "phrases", "delay"]
        ),
        .init(
            destination: SettingsRoute(section: .voiceDictation, cardID: "corrections.adaptive"),
            title: "Adaptive corrections",
            detail: "Learn from your quick word and phrase fixes",
            keywords: ["adaptive", "learned", "corrections", "backspace"]
        ),
        .init(
            destination: SettingsRoute(section: .browserAppControl, cardID: "browser.tasks"),
            title: "Browser and app control",
            detail: "Open the quick-start area for automation, browser reuse, and computer use",
            keywords: ["browser", "app control", "automation", "computer use", "setup"]
        ),
        .init(
            destination: SettingsRoute(section: .browserAppControl, cardID: "automation.permissions"),
            title: "Automation permissions",
            detail: "Review Accessibility, Screen Recording, Apple Events, and Full Disk Access",
            keywords: ["automation", "apple events", "accessibility", "screen recording", "full disk", "browser", "permissions"]
        ),
        .init(
            destination: SettingsRoute(section: .browserAppControl, cardID: "automation.browserProfile"),
            title: "Browser profile",
            detail: "Choose the Chrome, Brave, or Edge profile Open Assist should reuse",
            keywords: ["browser", "profile", "chrome", "brave", "edge", "session"]
        ),
        .init(
            destination: SettingsRoute(section: .browserAppControl, cardID: "automation.computerUse"),
            title: "Computer use",
            detail: "Turn screenshot-based desktop control on or off and review readiness",
            keywords: ["computer use", "desktop control", "mouse", "keyboard", "screenshot", "click", "type"]
        ),
        .init(
            destination: SettingsRoute(section: .browserAppControl, cardID: "automation.helperStatus"),
            title: "Helper status",
            detail: "See local automation helper readiness and setup issues",
            keywords: ["helper", "status", "issues", "readiness"]
        ),
        .init(
            destination: SettingsRoute(section: .permissionsPrivacy, cardID: "permissions.overview"),
            title: "Permission overview",
            detail: "See accessibility, microphone, speech, screen, and automation status",
            keywords: ["permissions", "accessibility", "microphone", "speech", "automation", "screen recording"]
        ),
        .init(
            destination: SettingsRoute(section: .advanced, cardID: "advanced.aiStudio"),
            title: "AI Studio",
            detail: aiStudioDescription,
            keywords: ["ai", "studio", "providers", "models", "memory", "advanced", "local ai"]
        ),
        .init(
            destination: SettingsRoute(section: .advanced, cardID: "advanced.providerStatus"),
            title: "Provider connection status",
            detail: "See which AI providers are ready",
            keywords: ["provider", "oauth", "api key", "openai", "anthropic", "google", "gemini", "connection"]
        ),
        .init(
            destination: SettingsRoute(
                section: .advanced,
                cardID: "integrations.notifications.localAPI",
                advancedPage: .automationNotifications
            ),
            title: "Automation notifications",
            detail: "Open the page for Claude Code, Codex CLI, and Codex Cloud alerts",
            keywords: ["automation", "notifications", "sources", "codex", "claude", "local api"]
        ),
        .init(
            destination: SettingsRoute(
                section: .advanced,
                cardID: "integrations.telegram.setup",
                advancedPage: .telegramRemote
            ),
            title: "Telegram remote",
            detail: "Control the selected Open Assist session from a private Telegram bot chat",
            keywords: ["telegram", "remote", "bot", "chat", "session"]
        ),
        .init(
            destination: SettingsRoute(section: .advanced, cardID: "advanced.appInfo"),
            title: "App info",
            detail: "See the version and check for updates",
            keywords: ["version", "updates", "app info", "build"]
        ),
        .init(
            destination: SettingsRoute(section: .advanced, cardID: "advanced.diagnostics"),
            title: "Crash logs",
            detail: "Open existing crash logs in Finder",
            keywords: ["crash", "logs", "diagnostics"]
        ),
        .init(
            destination: SettingsRoute(section: .advanced, cardID: "advanced.uninstall"),
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
            return SettingsSection.sidebarSections
        }

        let fromSectionTerms = SettingsSection.sidebarSections.filter { section in
            let haystack = ([section.title, section.subtitle] + section.searchTerms)
                .joined(separator: " ")
                .lowercased()
            return haystack.contains(normalized)
        }
        let fromEntries = Set(filteredSearchEntries(for: normalized).map(\.section))
        return SettingsSection.sidebarSections.filter { section in
            fromSectionTerms.contains(section) || fromEntries.contains(section)
        }
    }

    static func normalizedSearchQuery(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
