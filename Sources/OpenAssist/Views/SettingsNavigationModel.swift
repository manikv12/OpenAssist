import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable, Sendable {
    case assistant
    case voiceDictation
    case modelsConnections
    case automation
    case privacyPermissions
    case appearance
    case integrations
    case general
    case gettingStarted
    case dailyUse
    case browserAppControl
    case permissionsPrivacy
    case advanced

    var id: Self { self }

    static let sidebarSections: [SettingsSection] = [
        .assistant,
        .voiceDictation,
        .modelsConnections,
        .automation,
        .privacyPermissions,
        .appearance,
        .integrations,
        .general,
    ]

    var title: String {
        switch self {
        case .assistant:
            return "Assistant"
        case .voiceDictation:
            return "Voice & Dictation"
        case .modelsConnections:
            return "Models & Connections"
        case .automation:
            return "Automation"
        case .privacyPermissions:
            return "Privacy & Permissions"
        case .appearance:
            return "Appearance"
        case .integrations:
            return "Integrations"
        case .general:
            return "General"
        case .gettingStarted:
            return "Setup"
        case .dailyUse:
            return "AI & Assistant"
        case .browserAppControl:
            return "Automation"
        case .permissionsPrivacy:
            return "Privacy & Permissions"
        case .advanced:
            return "Advanced"
        }
    }

    var subtitle: String {
        switch self {
        case .assistant:
            return "Assistant behavior, voice replies, memory, and session defaults."
        case .voiceDictation:
            return "Microphone input, shortcuts, transcription, and correction quality."
        case .modelsConnections:
            return "Provider sign-in, model choice, local AI, and memory sources."
        case .automation:
            return "Browser reuse, app control, Computer Use, notifications, and local API."
        case .privacyPermissions:
            return "See permission status and jump to the exact macOS access screen."
        case .appearance:
            return "Theme, sounds, visual style, and waveform presentation."
        case .integrations:
            return "External services like Telegram remote."
        case .general:
            return "Backups, app info, diagnostics, updates, and uninstall."
        case .gettingStarted:
            return "Quick onboarding steps."
        case .dailyUse:
            return "Legacy AI and assistant section."
        case .browserAppControl:
            return "Legacy automation section."
        case .permissionsPrivacy:
            return "Legacy permissions section."
        case .advanced:
            return "Legacy advanced section."
        }
    }

    var iconName: String {
        switch self {
        case .assistant:
            return "sparkles"
        case .voiceDictation:
            return "waveform.and.mic"
        case .modelsConnections:
            return "slider.horizontal.3"
        case .automation:
            return "point.3.connected.trianglepath.dotted"
        case .privacyPermissions:
            return "hand.raised"
        case .appearance:
            return "paintbrush"
        case .integrations:
            return "paperplane"
        case .general:
            return "gearshape"
        case .gettingStarted:
            return "flag.checkered.2.crossed"
        case .dailyUse:
            return "sparkles"
        case .browserAppControl:
            return "point.3.connected.trianglepath.dotted"
        case .permissionsPrivacy:
            return "hand.raised"
        case .advanced:
            return "slider.horizontal.3"
        }
    }

    var tint: Color {
        switch self {
        case .assistant:
            return Color(red: 0.31, green: 0.58, blue: 0.95)
        case .voiceDictation:
            return Color(red: 0.27, green: 0.72, blue: 0.54)
        case .modelsConnections:
            return Color(red: 0.24, green: 0.66, blue: 0.95)
        case .automation:
            return Color(red: 0.23, green: 0.67, blue: 0.76)
        case .privacyPermissions:
            return Color(red: 0.84, green: 0.58, blue: 0.24)
        case .appearance:
            return Color(red: 0.78, green: 0.53, blue: 0.33)
        case .integrations:
            return Color(red: 0.52, green: 0.63, blue: 0.95)
        case .general:
            return Color(red: 0.62, green: 0.64, blue: 0.70)
        case .gettingStarted:
            return Color(red: 0.33, green: 0.63, blue: 0.95)
        case .dailyUse:
            return Color(red: 0.31, green: 0.58, blue: 0.95)
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
        case .assistant:
            return ["assistant", "agent", "sub-agent", "instructions", "assistant voice", "assistant memory", "assistant sessions"]
        case .voiceDictation:
            return ["voice", "dictation", "speech", "shortcut", "microphone", "whisper", "cleanup", "corrections"]
        case .modelsConnections:
            return ["models", "connections", "providers", "oauth", "api key", "local ai", "memory sources", "ai studio"]
        case .automation:
            return ["automation", "browser", "computer use", "notifications", "local api", "app action", "helper"]
        case .privacyPermissions:
            return ["permissions", "privacy", "accessibility", "microphone", "speech recognition", "screen recording"]
        case .appearance:
            return ["appearance", "theme", "style", "waveform", "sounds", "visual"]
        case .integrations:
            return ["integrations", "telegram", "remote", "bot"]
        case .general:
            return ["general", "backup", "updates", "diagnostics", "crash", "uninstall"]
        case .gettingStarted:
            return ["setup", "onboarding", "checklist"]
        case .dailyUse:
            return ["ai", "assistant", "legacy"]
        case .browserAppControl:
            return ["automation", "legacy"]
        case .permissionsPrivacy:
            return ["permissions", "privacy", "legacy"]
        case .advanced:
            return ["advanced", "legacy", "ai studio"]
        }
    }
}

enum SettingsSubsection: String, CaseIterable, Identifiable, Sendable {
    case onboardingChecklist = "gettingStarted.checklist"
    case onboardingOverview = "gettingStarted.setupOverview"

    case assistantOverview = "assistant.overview"
    case assistantSetup = "assistant.setup"
    case assistantVoice = "assistant.voice"
    case assistantMemory = "assistant.memory"
    case assistantInstructions = "assistant.instructions"
    case assistantAdvanced = "assistant.advanced"
    case assistantSessions = "assistant.sessions"

    case voiceOverview = "voice.tasks"
    case voiceOutput = "daily.output"
    case shortcutAgent = "shortcuts.agentShortcut"
    case shortcutHoldToTalk = "shortcuts.holdToTalk"
    case shortcutContinuousToggle = "shortcuts.continuousToggle"
    case shortcutCompactAssistant = "shortcuts.compactAssistantShortcut"
    case speechInputDevice = "speech.inputDevice"
    case speechTranscriptionEngine = "speech.transcriptionEngine"
    case speechModelLibrary = "speech.modelLibrary"
    case speechTextQuality = "speech.textQuality"
    case adaptiveCorrections = "corrections.adaptive"

    case modelsOverview = "models.overview"
    case modelsConnections = "models.connections"
    case modelsConversationMemory = "models.memory"
    case modelsMemorySources = "models.memorySources"
    case modelsSourceFolders = "models.sourceFolders"
    case modelsMemoryBrowser = "models.memoryBrowser"
    case modelsMaintenance = "models.maintenance"

    case automationOverview = "automation.overview"
    case automationPermissions = "automation.permissions"
    case automationBrowserProfile = "automation.browserProfile"
    case automationComputerUse = "automation.computerUse"
    case automationHelperStatus = "automation.helperStatus"
    case automationNotifications = "automation.notifications"
    case automationLocalAPI = "automation.localAPI"

    case permissionsOverview = "permissions.overview"

    case appearanceSounds = "appearance.sounds"
    case appearanceTheme = "appearance.theme"

    case integrationTelegram = "integrations.telegram.setup"

    case generalNotesBackup = "general.notesBackup"
    case generalAppInfo = "general.appInfo"
    case generalDiagnostics = "general.diagnostics"
    case generalUninstall = "general.uninstall"

    var id: Self { self }

    var title: String {
        switch self {
        case .onboardingChecklist:
            return "Setup Checklist"
        case .onboardingOverview:
            return "Overview"
        case .assistantOverview:
            return "Assistant"
        case .assistantSetup:
            return "Assistant Setup"
        case .assistantVoice:
            return "Assistant Voice"
        case .assistantMemory:
            return "Assistant Memory"
        case .assistantInstructions:
            return "Instructions"
        case .assistantAdvanced:
            return "Assistant Advanced"
        case .assistantSessions:
            return "Recent Sessions"
        case .voiceOverview:
            return "Overview"
        case .voiceOutput:
            return "Output"
        case .shortcutAgent:
            return "Agent Shortcut"
        case .shortcutHoldToTalk:
            return "Hold-to-Talk"
        case .shortcutContinuousToggle:
            return "Continuous Toggle"
        case .shortcutCompactAssistant:
            return "Compact Assistant"
        case .speechInputDevice:
            return "Microphone"
        case .speechTranscriptionEngine:
            return "Transcription"
        case .speechModelLibrary:
            return "Whisper Models"
        case .speechTextQuality:
            return "Text Quality"
        case .adaptiveCorrections:
            return "Corrections"
        case .modelsOverview:
            return "Overview"
        case .modelsConnections:
            return "Connections"
        case .modelsConversationMemory:
            return "Memory"
        case .modelsMemorySources:
            return "Memory Sources"
        case .modelsSourceFolders:
            return "Source Folders"
        case .modelsMemoryBrowser:
            return "Memory Browser"
        case .modelsMaintenance:
            return "Maintenance"
        case .automationOverview:
            return "Overview"
        case .automationPermissions:
            return "Permissions"
        case .automationBrowserProfile:
            return "Browser Profile"
        case .automationComputerUse:
            return "Computer Use"
        case .automationHelperStatus:
            return "Helper Status"
        case .automationNotifications:
            return "Notifications"
        case .automationLocalAPI:
            return "Local API"
        case .permissionsOverview:
            return "Overview"
        case .appearanceSounds:
            return "Sounds"
        case .appearanceTheme:
            return "Theme"
        case .integrationTelegram:
            return "Telegram"
        case .generalNotesBackup:
            return "Notes Backup"
        case .generalAppInfo:
            return "App Info"
        case .generalDiagnostics:
            return "Diagnostics"
        case .generalUninstall:
            return "Uninstall"
        }
    }

    var section: SettingsSection {
        switch self {
        case .onboardingChecklist, .onboardingOverview,
             .assistantOverview, .assistantSetup, .assistantVoice, .assistantMemory,
             .assistantInstructions, .assistantAdvanced, .assistantSessions:
            return .assistant
        case .voiceOverview, .voiceOutput, .shortcutAgent, .shortcutHoldToTalk,
             .shortcutContinuousToggle, .shortcutCompactAssistant, .speechInputDevice,
             .speechTranscriptionEngine, .speechModelLibrary, .speechTextQuality,
             .adaptiveCorrections:
            return .voiceDictation
        case .modelsOverview, .modelsConnections, .modelsConversationMemory,
             .modelsMemorySources, .modelsSourceFolders, .modelsMemoryBrowser,
             .modelsMaintenance:
            return .modelsConnections
        case .automationOverview, .automationPermissions, .automationBrowserProfile,
             .automationComputerUse, .automationHelperStatus, .automationNotifications,
             .automationLocalAPI:
            return .automation
        case .permissionsOverview:
            return .privacyPermissions
        case .appearanceSounds, .appearanceTheme:
            return .appearance
        case .integrationTelegram:
            return .integrations
        case .generalNotesBackup, .generalAppInfo, .generalDiagnostics, .generalUninstall:
            return .general
        }
    }

    var studioPageRawValue: String? {
        switch self {
        case .assistantSetup:
            return "assistantSetup"
        case .assistantVoice:
            return "assistantVoice"
        case .assistantMemory:
            return "assistantMemory"
        case .assistantInstructions:
            return "assistantInstructions"
        case .assistantAdvanced:
            return "assistantLimits"
        case .assistantSessions:
            return "assistantSessions"
        case .modelsConnections:
            return "models"
        case .modelsConversationMemory:
            return "conversationMemory"
        case .modelsMemorySources:
            return "memorySources"
        case .modelsSourceFolders:
            return "sourceFolders"
        case .modelsMemoryBrowser:
            return "browser"
        case .modelsMaintenance:
            return "actions"
        default:
            return nil
        }
    }

    static func fromLegacyCardID(_ cardID: String?) -> SettingsSubsection? {
        guard let normalized = cardID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalized.isEmpty else {
            return nil
        }

        switch normalized {
        case "gettingStarted.checklist":
            return .onboardingChecklist
        case "gettingStarted.setupOverview":
            return .onboardingOverview
        case "daily.tasks", "daily.assistant":
            return .assistantOverview
        case "daily.output":
            return .voiceOutput
        case "daily.sounds":
            return .appearanceSounds
        case "daily.appearance":
            return .appearanceTheme
        case "voice.tasks":
            return .voiceOverview
        case "shortcuts.agentShortcut":
            return .shortcutAgent
        case "shortcuts.holdToTalk":
            return .shortcutHoldToTalk
        case "shortcuts.continuousToggle":
            return .shortcutContinuousToggle
        case "shortcuts.compactAssistantShortcut":
            return .shortcutCompactAssistant
        case "speech.inputDevice":
            return .speechInputDevice
        case "speech.transcriptionEngine":
            return .speechTranscriptionEngine
        case "speech.modelLibrary":
            return .speechModelLibrary
        case "speech.textQuality":
            return .speechTextQuality
        case "corrections.adaptive":
            return .adaptiveCorrections
        case "browser.tasks":
            return .automationOverview
        case "automation.permissions":
            return .automationPermissions
        case "automation.browserProfile":
            return .automationBrowserProfile
        case "automation.computerUse":
            return .automationComputerUse
        case "automation.helperStatus":
            return .automationHelperStatus
        case "permissions.overview":
            return .permissionsOverview
        case "advanced.aiStudio", "advanced.providerStatus":
            return .modelsConnections
        case "advanced.notesBackup":
            return .generalNotesBackup
        case "integrations.notifications.localAPI":
            return .automationLocalAPI
        case "integrations.telegram.setup":
            return .integrationTelegram
        case "advanced.appInfo":
            return .generalAppInfo
        case "advanced.diagnostics":
            return .generalDiagnostics
        case "advanced.uninstall":
            return .generalUninstall
        default:
            return SettingsSubsection(rawValue: normalized)
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
    let subsection: SettingsSubsection?
    let advancedPage: SettingsAdvancedPage
    let opensAIStudio: Bool

    var cardID: String? {
        subsection?.rawValue
    }

    var studioPageRawValue: String? {
        subsection?.studioPageRawValue
    }

    init(
        section: SettingsSection,
        subsection: SettingsSubsection? = nil,
        cardID: String? = nil,
        advancedPage: SettingsAdvancedPage? = nil,
        opensAIStudio: Bool = false
    ) {
        let resolvedSubsection = subsection ?? SettingsSubsection.fromLegacyCardID(cardID)
        self.section = resolvedSubsection?.section ?? section
        self.subsection = resolvedSubsection
        self.advancedPage = advancedPage ?? .overview
        self.opensAIStudio = opensAIStudio
    }

    static let gettingStartedHome = SettingsRoute(
        section: .assistant,
        subsection: .onboardingChecklist
    )
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
        case .notStarted, .needsAttention:
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
        return "\(section.rawValue)-\(card)-\(title)"
    }
}

enum SettingsNavigationModel {
    static let modelsDescription = "Provider sign-in, model choices, local AI, memory sources, and maintenance"
    static let aiStudioDescription = modelsDescription

    static let searchEntries: [SettingSearchEntry] = [
        .init(
            destination: .gettingStartedHome,
            title: "Setup checklist",
            detail: "Open the onboarding checklist that links into the real feature sections",
            keywords: ["getting started", "setup", "onboarding", "first run", "checklist"]
        ),
        .init(
            destination: SettingsRoute(section: .assistant, subsection: .assistantOverview),
            title: "Assistant overview",
            detail: "Global assistant defaults and quick links",
            keywords: ["assistant", "agent", "assistant settings", "setup"]
        ),
        .init(
            destination: SettingsRoute(section: .assistant, subsection: .assistantVoice),
            title: "Assistant voice",
            detail: "Reply voice output, engine, fallback, and voice health",
            keywords: ["assistant voice", "voice output", "hume", "tts", "reply voice"]
        ),
        .init(
            destination: SettingsRoute(section: .assistant, subsection: .assistantMemory),
            title: "Assistant memory",
            detail: "Thread memory, long-term review, and memory defaults",
            keywords: ["assistant memory", "memory review", "thread memory", "lessons"]
        ),
        .init(
            destination: SettingsRoute(section: .assistant, subsection: .assistantInstructions),
            title: "Assistant instructions",
            detail: "Global instructions sent with every assistant session",
            keywords: ["instructions", "custom instructions", "assistant prompt", "global instructions"]
        ),
        .init(
            destination: SettingsRoute(section: .assistant, subsection: .assistantAdvanced),
            title: "Assistant advanced",
            detail: "Turn limits, repeated command limits, and advanced assistant behavior",
            keywords: ["tool limits", "tool calls", "repeated command", "assistant advanced", "sub-agent"]
        ),
        .init(
            destination: SettingsRoute(section: .assistant, subsection: .assistantSessions),
            title: "Recent assistant sessions",
            detail: "Saved assistant sessions in Open Assist",
            keywords: ["recent sessions", "assistant sessions", "saved chats"]
        ),
        .init(
            destination: SettingsRoute(section: .voiceDictation, subsection: .voiceOverview),
            title: "Voice and dictation",
            detail: "Microphone, dictation, shortcuts, and speech quality",
            keywords: ["voice", "dictation", "speech", "microphone", "shortcuts"]
        ),
        .init(
            destination: SettingsRoute(section: .voiceDictation, subsection: .shortcutAgent),
            title: "Agent shortcut",
            detail: "Hold to speak and paste into the assistant box",
            keywords: ["agent shortcut", "assistant shortcut", "voice shortcut"]
        ),
        .init(
            destination: SettingsRoute(section: .voiceDictation, subsection: .shortcutHoldToTalk),
            title: "Hold-to-talk shortcut",
            detail: "Press-and-hold dictation shortcut",
            keywords: ["hold to talk", "shortcut", "keyboard"]
        ),
        .init(
            destination: SettingsRoute(section: .voiceDictation, subsection: .speechInputDevice),
            title: "Microphone device",
            detail: "Choose a microphone or auto-detect one",
            keywords: ["microphone", "input device", "device picker"]
        ),
        .init(
            destination: SettingsRoute(section: .voiceDictation, subsection: .speechTranscriptionEngine),
            title: "Transcription engine",
            detail: "Switch Apple Speech, whisper.cpp, or a cloud provider",
            keywords: ["transcription engine", "whisper", "apple speech", "cloud provider", "recognition"]
        ),
        .init(
            destination: SettingsRoute(section: .voiceDictation, subsection: .speechModelLibrary),
            title: "Whisper model library",
            detail: "Download and manage whisper.cpp models",
            keywords: ["whisper", "whisper model", "model library"]
        ),
        .init(
            destination: SettingsRoute(section: .voiceDictation, subsection: .speechTextQuality),
            title: "Text quality",
            detail: "Finalize delay, cleanup mode, and custom phrases",
            keywords: ["cleanup", "finalize delay", "custom phrases", "text quality"]
        ),
        .init(
            destination: SettingsRoute(section: .voiceDictation, subsection: .adaptiveCorrections),
            title: "Adaptive corrections",
            detail: "Learn from your quick word and phrase fixes",
            keywords: ["adaptive corrections", "learned corrections", "voice fixes"]
        ),
        .init(
            destination: SettingsRoute(section: .modelsConnections, subsection: .modelsConnections),
            title: "Models and connections",
            detail: modelsDescription,
            keywords: ["models", "connections", "providers", "oauth", "api key", "ai studio"]
        ),
        .init(
            destination: SettingsRoute(section: .modelsConnections, subsection: .modelsConversationMemory),
            title: "Conversation memory",
            detail: "Shared context, saved history, and memory plumbing",
            keywords: ["conversation memory", "memory", "history", "context"]
        ),
        .init(
            destination: SettingsRoute(section: .modelsConnections, subsection: .modelsMemorySources),
            title: "Memory sources",
            detail: "Choose which apps and source providers feed memory",
            keywords: ["memory sources", "providers", "source providers"]
        ),
        .init(
            destination: SettingsRoute(section: .modelsConnections, subsection: .modelsSourceFolders),
            title: "Source folders",
            detail: "Choose which folders are included in memory indexing",
            keywords: ["source folders", "folders", "memory folders"]
        ),
        .init(
            destination: SettingsRoute(section: .modelsConnections, subsection: .modelsMemoryBrowser),
            title: "Memory browser",
            detail: "Search and inspect indexed memories",
            keywords: ["memory browser", "indexed memories", "browse memory"]
        ),
        .init(
            destination: SettingsRoute(section: .modelsConnections, subsection: .modelsMaintenance),
            title: "Memory maintenance",
            detail: "Rescan, rebuild, and cleanup model and memory data",
            keywords: ["maintenance", "rebuild", "rescan", "clear memories"]
        ),
        .init(
            destination: SettingsRoute(section: .automation, subsection: .automationOverview),
            title: "Automation overview",
            detail: "Browser reuse, app control, Computer Use, and automation delivery",
            keywords: ["automation", "browser automation", "computer use", "local api"]
        ),
        .init(
            destination: SettingsRoute(section: .automation, subsection: .automationBrowserProfile),
            title: "Browser profile",
            detail: "Choose the Chrome, Brave, or Edge profile Open Assist should reuse",
            keywords: ["browser profile", "chrome", "brave", "edge", "session"]
        ),
        .init(
            destination: SettingsRoute(section: .automation, subsection: .automationComputerUse),
            title: "Computer use",
            detail: "Turn screenshot-based desktop control on or off and review readiness",
            keywords: ["computer use", "desktop control", "mouse", "keyboard", "screenshots"]
        ),
        .init(
            destination: SettingsRoute(section: .automation, subsection: .automationLocalAPI),
            title: "Automation local API",
            detail: "Local API, Claude hooks, Codex CLI example, and shared delivery settings",
            keywords: ["local api", "claude hooks", "codex cli", "automation token"]
        ),
        .init(
            destination: SettingsRoute(section: .privacyPermissions, subsection: .permissionsOverview),
            title: "Permission overview",
            detail: "Accessibility, microphone, speech, screen recording, and automation status",
            keywords: ["permissions", "privacy", "accessibility", "microphone", "screen recording"]
        ),
        .init(
            destination: SettingsRoute(section: .appearance, subsection: .appearanceTheme),
            title: "Appearance",
            detail: "Theme, interface style, waveform look, and visual feedback",
            keywords: ["appearance", "theme", "waveform", "style", "colors"]
        ),
        .init(
            destination: SettingsRoute(section: .appearance, subsection: .appearanceSounds),
            title: "Feedback sounds",
            detail: "Choose dictation start, stop, processing, and pasted sounds",
            keywords: ["sounds", "feedback", "dictation sounds", "audio cues"]
        ),
        .init(
            destination: SettingsRoute(section: .integrations, subsection: .integrationTelegram),
            title: "Telegram remote",
            detail: "Control the selected Open Assist session from a private Telegram bot chat",
            keywords: ["telegram", "remote", "bot", "chat", "session"]
        ),
        .init(
            destination: SettingsRoute(section: .general, subsection: .generalNotesBackup),
            title: "Notes backup",
            detail: "Choose the notes backup folder, back up now, or restore an older backup",
            keywords: ["notes backup", "backup", "restore", "history"]
        ),
        .init(
            destination: SettingsRoute(section: .general, subsection: .generalAppInfo),
            title: "App info",
            detail: "See the version and check for updates",
            keywords: ["version", "updates", "build", "app info"]
        ),
        .init(
            destination: SettingsRoute(section: .general, subsection: .generalDiagnostics),
            title: "Crash logs",
            detail: "Open existing crash logs in Finder",
            keywords: ["crash", "logs", "diagnostics"]
        ),
        .init(
            destination: SettingsRoute(section: .general, subsection: .generalUninstall),
            title: "Uninstall Open Assist",
            detail: "Remove the app and clear local settings",
            keywords: ["uninstall", "remove", "reset"]
        ),
    ]

    static func filteredSearchEntries(for query: String) -> [SettingSearchEntry] {
        let normalized = normalizedSearchQuery(query)
        guard !normalized.isEmpty else { return [] }
        return searchEntries.filter { entry in
            let haystack = ([entry.title, entry.detail] + entry.keywords)
                .joined(separator: " ")
                .lowercased()
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
