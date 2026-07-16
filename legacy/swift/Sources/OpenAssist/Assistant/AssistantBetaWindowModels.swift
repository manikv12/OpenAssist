import Foundation
import SwiftUI

enum AssistantBetaBannerTone: String, Equatable {
    case info
    case success
    case warning
    case error
}

enum AssistantBetaBannerAction: Equatable {
    case installHelp
    case openSettings
}

struct AssistantBetaBanner: Identifiable, Equatable {
    let id: String
    var title: String
    var message: String
    var symbol: String
    var tone: AssistantBetaBannerTone
    var actionTitle: String?
    var action: AssistantBetaBannerAction?

    init(
        id: String = UUID().uuidString,
        title: String,
        message: String,
        symbol: String,
        tone: AssistantBetaBannerTone,
        actionTitle: String? = nil,
        action: AssistantBetaBannerAction? = nil
    ) {
        self.id = id
        self.title = title
        self.message = message
        self.symbol = symbol
        self.tone = tone
        self.actionTitle = actionTitle
        self.action = action
    }
}

enum AssistantBetaVoiceDraftState: Equatable {
    case idle
    case listening(message: String)
    case captured(text: String)
    case failed(message: String)
}

enum AssistantBetaTranscriptRole: String, Equatable {
    case system
    case user
    case assistant
    case tool
}

struct AssistantBetaTranscriptItem: Identifiable, Equatable {
    let id: String
    var role: AssistantBetaTranscriptRole
    var title: String
    var body: String
    var footnote: String?
    var isStreaming: Bool
    var timestamp: Date

    init(
        id: String = UUID().uuidString,
        role: AssistantBetaTranscriptRole,
        title: String,
        body: String,
        footnote: String? = nil,
        isStreaming: Bool = false,
        timestamp: Date = .now
    ) {
        self.id = id
        self.role = role
        self.title = title
        self.body = body
        self.footnote = footnote
        self.isStreaming = isStreaming
        self.timestamp = timestamp
    }
}

enum AssistantBetaSessionState: String, Equatable {
    case ready
    case running
    case waiting
    case completed
    case failed
}

struct AssistantBetaSessionSummary: Identifiable, Equatable {
    let id: String
    var title: String
    var subtitle: String
    var sourceLabel: String
    var status: AssistantBetaSessionState
    var updatedAt: Date
    var badges: [String]
    var detailPreview: String?

    init(
        id: String,
        title: String,
        subtitle: String,
        sourceLabel: String,
        status: AssistantBetaSessionState,
        updatedAt: Date = .now,
        badges: [String] = [],
        detailPreview: String? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.sourceLabel = sourceLabel
        self.status = status
        self.updatedAt = updatedAt
        self.badges = badges
        self.detailPreview = detailPreview
    }
}

struct AssistantBetaSessionFact: Identifiable, Equatable {
    let id: String
    var label: String
    var value: String

    init(id: String = UUID().uuidString, label: String, value: String) {
        self.id = id
        self.label = label
        self.value = value
    }
}

struct AssistantBetaSessionDetail: Equatable {
    var sessionID: String
    var headline: String
    var summary: String
    var statusLine: String
    var primaryActionTitle: String
    var secondaryActionTitle: String
    var facts: [AssistantBetaSessionFact]
    var notes: [String]

    init(
        sessionID: String,
        headline: String,
        summary: String,
        statusLine: String,
        primaryActionTitle: String = "Resume Session",
        secondaryActionTitle: String = "Open Session",
        facts: [AssistantBetaSessionFact] = [],
        notes: [String] = []
    ) {
        self.sessionID = sessionID
        self.headline = headline
        self.summary = summary
        self.statusLine = statusLine
        self.primaryActionTitle = primaryActionTitle
        self.secondaryActionTitle = secondaryActionTitle
        self.facts = facts
        self.notes = notes
    }
}

struct AssistantBetaInstallHelp: Equatable {
    var title: String
    var message: String
    var steps: [String]
    var primaryButtonTitle: String
    var secondaryButtonTitle: String?

    init(
        title: String,
        message: String,
        steps: [String],
        primaryButtonTitle: String = "Show Install Help",
        secondaryButtonTitle: String? = "Open Settings"
    ) {
        self.title = title
        self.message = message
        self.steps = steps
        self.primaryButtonTitle = primaryButtonTitle
        self.secondaryButtonTitle = secondaryButtonTitle
    }
}

struct AssistantBetaWindowActions {
    var onNewTask: (() -> Void)?
    var onSend: ((String) -> Void)?
    var onSelectSession: ((AssistantBetaSessionSummary) -> Void)?
    var onResumeSession: ((AssistantBetaSessionSummary) -> Void)?
    var onOpenSession: ((AssistantBetaSessionSummary) -> Void)?
    var onRefreshSessions: (() -> Void)?
    var onInstallHelp: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    init(
        onNewTask: (() -> Void)? = nil,
        onSend: ((String) -> Void)? = nil,
        onSelectSession: ((AssistantBetaSessionSummary) -> Void)? = nil,
        onResumeSession: ((AssistantBetaSessionSummary) -> Void)? = nil,
        onOpenSession: ((AssistantBetaSessionSummary) -> Void)? = nil,
        onRefreshSessions: (() -> Void)? = nil,
        onInstallHelp: (() -> Void)? = nil,
        onOpenSettings: (() -> Void)? = nil
    ) {
        self.onNewTask = onNewTask
        self.onSend = onSend
        self.onSelectSession = onSelectSession
        self.onResumeSession = onResumeSession
        self.onOpenSession = onOpenSession
        self.onRefreshSessions = onRefreshSessions
        self.onInstallHelp = onInstallHelp
        self.onOpenSettings = onOpenSettings
    }
}

enum AssistantBetaOrbPhase: String, Equatable {
    case idle
    case listening
    case thinking
    case acting
    case waiting
    case error
}

struct AssistantBetaOrbState: Equatable {
    var phase: AssistantBetaOrbPhase
    var title: String
    var detail: String
    var audioLevel: Double

    init(
        phase: AssistantBetaOrbPhase,
        title: String,
        detail: String,
        audioLevel: Double = 0
    ) {
        self.phase = phase
        self.title = title
        self.detail = detail
        self.audioLevel = max(0, min(audioLevel, 1))
    }
}

@MainActor
final class AssistantBetaWindowModel: ObservableObject {
    @Published var draftText: String
    @Published var voiceDraftState: AssistantBetaVoiceDraftState
    @Published var banners: [AssistantBetaBanner]
    @Published var transcriptItems: [AssistantBetaTranscriptItem]
    @Published var sessions: [AssistantBetaSessionSummary]
    @Published var selectedSessionID: String?
    @Published var sessionDetail: AssistantBetaSessionDetail?
    @Published var installHelp: AssistantBetaInstallHelp?
    @Published var isSending: Bool
    @Published var isRefreshingSessions: Bool
    @Published var isRuntimeBusy: Bool
    @Published var composerPlaceholder: String
    @Published var transcriptEmptyTitle: String
    @Published var transcriptEmptyMessage: String

    init(
        draftText: String = "",
        voiceDraftState: AssistantBetaVoiceDraftState = .idle,
        banners: [AssistantBetaBanner] = [],
        transcriptItems: [AssistantBetaTranscriptItem] = [],
        sessions: [AssistantBetaSessionSummary] = [],
        selectedSessionID: String? = nil,
        sessionDetail: AssistantBetaSessionDetail? = nil,
        installHelp: AssistantBetaInstallHelp? = nil,
        isSending: Bool = false,
        isRefreshingSessions: Bool = false,
        isRuntimeBusy: Bool = false,
        composerPlaceholder: String = "Ask your assistant to organize files, open something, or help with a task.",
        transcriptEmptyTitle: String = "Nothing is running yet",
        transcriptEmptyMessage: String = "Start with a typed task or use the voice shortcut from the menu bar."
    ) {
        self.draftText = draftText
        self.voiceDraftState = voiceDraftState
        self.banners = banners
        self.transcriptItems = transcriptItems
        self.sessions = sessions
        self.selectedSessionID = selectedSessionID ?? sessions.first?.id
        self.sessionDetail = sessionDetail
        self.installHelp = installHelp
        self.isSending = isSending
        self.isRefreshingSessions = isRefreshingSessions
        self.isRuntimeBusy = isRuntimeBusy
        self.composerPlaceholder = composerPlaceholder
        self.transcriptEmptyTitle = transcriptEmptyTitle
        self.transcriptEmptyMessage = transcriptEmptyMessage
    }

    var trimmedDraftText: String {
        draftText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canSend: Bool {
        !trimmedDraftText.isEmpty && !isSending
    }

    var selectedSession: AssistantBetaSessionSummary? {
        guard let selectedSessionID else { return sessions.first }
        return sessions.first { $0.id == selectedSessionID } ?? sessions.first
    }

    var resolvedSessionDetail: AssistantBetaSessionDetail? {
        if let sessionDetail, sessionDetail.sessionID == selectedSession?.id {
            return sessionDetail
        }
        guard let selectedSession else { return nil }
        return AssistantBetaSessionDetail(
            sessionID: selectedSession.id,
            headline: selectedSession.title,
            summary: selectedSession.detailPreview ?? selectedSession.subtitle,
            statusLine: selectedSession.status.rawValue.capitalized,
            facts: [
                AssistantBetaSessionFact(label: "Source", value: selectedSession.sourceLabel),
                AssistantBetaSessionFact(
                    label: "Updated",
                    value: RelativeDateTimeFormatter().localizedString(for: selectedSession.updatedAt, relativeTo: .now)
                )
            ],
            notes: selectedSession.badges
        )
    }

    func selectSession(_ session: AssistantBetaSessionSummary) {
        selectedSessionID = session.id
    }
}

@MainActor
final class AssistantBetaOrbHUDModel: ObservableObject {
    @Published var state: AssistantBetaOrbState
    @Published var isVisible: Bool

    init(
        state: AssistantBetaOrbState = AssistantBetaOrbState(
            phase: .idle,
            title: "Assistant is ready",
            detail: "Use the top bar or the assistant window to begin."
        ),
        isVisible: Bool = true
    ) {
        self.state = state
        self.isVisible = isVisible
    }
}

#if DEBUG
extension AssistantBetaWindowModel {
    static var preview: AssistantBetaWindowModel {
        AssistantBetaWindowModel(
            draftText: "Please clean up my Downloads folder and group invoices by month.",
            voiceDraftState: .captured(text: "Clean up my downloads and make it easy to review."),
            banners: [
                AssistantBetaBanner(
                    title: "Accessibility permission is still needed",
                    message: "Turn it on once, then the assistant can help with app controls and menus.",
                    symbol: "figure.wave.circle",
                    tone: .warning,
                    actionTitle: "Open Settings",
                    action: .openSettings
                ),
                AssistantBetaBanner(
                    title: "Codex install help is available",
                    message: "If the helper is missing, Open Assist can guide the user through install and sign-in.",
                    symbol: "arrow.down.circle",
                    tone: .info,
                    actionTitle: "Install Help",
                    action: .installHelp
                )
            ],
            transcriptItems: [
                AssistantBetaTranscriptItem(
                    role: .system,
                    title: "System",
                    body: "Session opened in ~/Downloads.",
                    footnote: "Ready to inspect files"
                ),
                AssistantBetaTranscriptItem(
                    role: .user,
                    title: "You",
                    body: "Please group invoices by month and move screenshots into a Screenshots folder."
                ),
                AssistantBetaTranscriptItem(
                    role: .assistant,
                    title: "Assistant",
                    body: "I scanned 184 items. I found 36 invoices, 42 screenshots, and 11 archives that I will leave untouched.",
                    footnote: "Streaming now",
                    isStreaming: true
                ),
                AssistantBetaTranscriptItem(
                    role: .tool,
                    title: "Tool",
                    body: "Reviewing folder names and file dates.",
                    footnote: "Finder + metadata"
                )
            ],
            sessions: [
                AssistantBetaSessionSummary(
                    id: "local-1",
                    title: "Downloads cleanup",
                    subtitle: "Grouped invoices, screenshots, and travel files",
                    sourceLabel: "Codex CLI",
                    status: .running,
                    updatedAt: Date().addingTimeInterval(-120),
                    badges: ["Live", "Files"],
                    detailPreview: "Working inside ~/Downloads with a batch of suggested file moves."
                ),
                AssistantBetaSessionSummary(
                    id: "local-2",
                    title: "Project notes tidy-up",
                    subtitle: "Rewrote meeting notes and opened the summary",
                    sourceLabel: "Codex CLI",
                    status: .completed,
                    updatedAt: Date().addingTimeInterval(-3800),
                    badges: ["Done"],
                    detailPreview: "Finished with a short markdown summary and 3 renamed files."
                ),
                AssistantBetaSessionSummary(
                    id: "remote-1",
                    title: "Inbox review",
                    subtitle: "Waiting for permission to control Mail",
                    sourceLabel: "Remote Session",
                    status: .waiting,
                    updatedAt: Date().addingTimeInterval(-640),
                    badges: ["Needs permission", "UI help"],
                    detailPreview: "Paused before clicking a Mail toolbar item."
                )
            ],
            selectedSessionID: "local-1",
            sessionDetail: AssistantBetaSessionDetail(
                sessionID: "local-1",
                headline: "Downloads cleanup",
                summary: "The assistant is preparing a tidy structure for invoices, screenshots, and loose documents.",
                statusLine: "Running now",
                facts: [
                    AssistantBetaSessionFact(label: "Working folder", value: "~/Downloads"),
                    AssistantBetaSessionFact(label: "Next step", value: "Show file move plan"),
                    AssistantBetaSessionFact(label: "Last update", value: "2 minutes ago")
                ],
                notes: [
                    "Resume continues the same task.",
                    "Open shows the session transcript in the full app flow."
                ]
            ),
            installHelp: AssistantBetaInstallHelp(
                title: "Need Codex?",
                message: "The app can guide the user through install and sign-in. This keeps the experience friendly even if the tool is missing.",
                steps: [
                    "Check whether Codex is already installed.",
                    "Show the correct install command for this Mac.",
                    "Guide the user to sign in before starting a session."
                ]
            )
        )
    }
}

extension AssistantBetaOrbHUDModel {
    static var previewListening: AssistantBetaOrbHUDModel {
        AssistantBetaOrbHUDModel(
            state: AssistantBetaOrbState(
                phase: .listening,
                title: "Listening for your task",
                detail: "Speak normally. Open Assist will put the draft in the assistant window.",
                audioLevel: 0.72
            )
        )
    }
}
#endif
