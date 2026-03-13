import AppKit
import SwiftUI

private let kOrbPopupSizeKey = "assistantOrbPopupSize"

// MARK: - Model

@MainActor
final class AssistantOrbHUDModel: ObservableObject {
    @Published var state: AssistantHUDState = .idle
    @Published var level: Float = 0
    @Published var interactionMode: AssistantInteractionMode = .conversational
    @Published var busySessionID: String?

    // Expansion state
    @Published var isExpanded = false
    @Published var isLoadingSessions = false
    @Published var sessions: [AssistantSessionSummary] = []
    @Published var selectedSessionID: String?
    @Published var messageText = ""
    @Published var attachments: [AssistantAttachment] = []
    @Published var shouldFocusTextField = false

    // Done detail popup
    @Published var showDoneDetail = false
    @Published private(set) var storedDoneDetailText: String?
    var doneDetailText: String? { storedDoneDetailText }
    @Published var showPlanDetail = false
    @Published private(set) var storedProposedPlanText: String?
    var proposedPlanText: String? { storedProposedPlanText }

    // Live working detail popup
    @Published var showWorkingDetail = false
    @Published var showCompactComposer = false
    @Published var workingToolActivity: [AssistantToolCallState] = []
    @Published var activeSessionSummary: AssistantSessionSummary?

    // Model selection
    @Published var availableModels: [AssistantModelOption] = []
    @Published var selectedModelSummary: String = ""
    @Published var controllerModeSwitchSuggestion: AssistantModeSwitchSuggestion?
    @Published var canStopActiveTurn = false

    // Voice recording
    @Published var isVoiceRecording = false
    @Published var notchDockRevealed = false
    @Published var notchUsesHardwareOutline = false
    @Published var notchHardwareOutlineSize: NSSize = .zero
    @Published var notchDockVisibleWidth: CGFloat = 160
    @Published var notchDockVisibleHeight: CGFloat = 4

    // Popup size (user-resizable, persisted)
    @Published var popupSize: NSSize = Layout.defaultPopupSize

    enum Layout {
        static let defaultPopupSize = NSSize(width: 340, height: 456)
        static let minPopupSize = NSSize(width: 280, height: 320)
        static let maxPopupSize = NSSize(width: 500, height: 700)
        static let expandedSize = NSSize(width: 300, height: 512)
    }

    // Permission request popup
    @Published var pendingPermissionRequest: AssistantPermissionRequest?

    // Callbacks wired by the manager
    var onRefreshSessions: (() async -> Void)?
    var onSendMessage: ((String, String?) -> Void)?
    var onSessionSelected: ((AssistantSessionSummary) -> Void)?
    var onOpenSession: ((AssistantSessionSummary) -> Void)?
    var onNewSession: (() async -> Void)?
    var onChooseModel: ((String) -> Void)?
    var onOpenAttachmentPicker: (() -> Void)?
    var onAddAttachment: ((AssistantAttachment) -> Void)?
    var onRemoveAttachment: ((UUID) -> Void)?
    var onStartVoiceRecording: (() -> Void)?
    var onStopVoiceRecording: (() -> Void)?
    var onStopActiveTurn: (() -> Void)?
    var onHideDock: (() -> Void)?
    var onResolvePermission: ((String) -> Void)?
    var onSubmitPermissionAnswers: (([String: [String]]) -> Void)?
    var onCancelPermission: (() -> Void)?
    var onAlwaysAllowPermission: ((String) -> Void)?
    var onExecutePlan: (() -> Void)?
    var onDismissPlan: (() -> Void)?
    var onModeChanged: ((AssistantInteractionMode) -> Void)?
    var onApplyModeSwitchSuggestion: ((AssistantModeSwitchChoice) -> Void)?
    var onDismissModeSwitchSuggestion: (() -> Void)?

    init() {
        if let dict = UserDefaults.standard.dictionary(forKey: kOrbPopupSizeKey),
           let w = dict["width"] as? Double, let h = dict["height"] as? Double {
            let clamped = NSSize(
                width: min(max(w, Layout.minPopupSize.width), Layout.maxPopupSize.width),
                height: min(max(h, Layout.minPopupSize.height), Layout.maxPopupSize.height)
            )
            popupSize = clamped
        }
    }

    func persistPopupSize() {
        let dict: [String: Double] = [
            "width": Double(popupSize.width),
            "height": Double(popupSize.height)
        ]
        UserDefaults.standard.set(dict, forKey: kOrbPopupSizeKey)
    }

    func update(state: AssistantHUDState) {
        self.state = state

        switch state.phase {
        case .success, .failed:
            let trimmedDetail = state.detail?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            storedDoneDetailText = trimmedDetail
            showDoneDetail = trimmedDetail != nil && storedProposedPlanText?.nonEmpty == nil
            showWorkingDetail = false
            showCompactComposer = false
            shouldFocusTextField = false
        case .idle:
            // Keep the completion/error popup visible until the user closes it.
            showWorkingDetail = false
            break
        case .waitingForPermission:
            storedDoneDetailText = nil
            showDoneDetail = false
            showWorkingDetail = false
            showCompactComposer = false
            shouldFocusTextField = false
        case .listening, .thinking, .acting, .streaming:
            storedDoneDetailText = nil
            showDoneDetail = false
            if showCompactComposer {
                showCompactComposer = false
                showWorkingDetail = true
            }
            shouldFocusTextField = false
        }
    }

    var canPresentWorkingDetail: Bool {
        guard shouldOfferWorkingDetail(for: state.phase) else { return false }
        if state.detail?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty != nil {
            return true
        }
        if !workingToolActivity.isEmpty {
            return true
        }
        if activeSessionSummary != nil {
            return true
        }
        return false
    }

    @discardableResult
    func presentWorkingDetailIfAvailable() -> Bool {
        guard canPresentWorkingDetail else { return false }
        showWorkingDetail = true
        Task { await onRefreshSessions?() }
        return true
    }

    @discardableResult
    func presentDoneDetailIfAvailable() -> Bool {
        guard storedDoneDetailText?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty != nil else {
            return false
        }
        showDoneDetail = true
        Task { await onRefreshSessions?() }
        return true
    }

    func dismissWorkingDetail() {
        showWorkingDetail = false
    }

    func showPlanPreview(_ text: String) {
        storedProposedPlanText = text
        showPlanDetail = true
        showDoneDetail = false
        showWorkingDetail = false
        showCompactComposer = false
        Task { await onRefreshSessions?() }
    }

    func dismissPlanDetail() {
        showPlanDetail = false
        storedProposedPlanText = nil
    }

    var canPresentCompactComposer: Bool {
        if selectedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty != nil {
            return true
        }
        if activeSessionSummary != nil {
            return true
        }
        return true
    }

    @discardableResult
    func presentCompactComposerIfAvailable() -> Bool {
        guard canPresentCompactComposer else { return false }
        if selectedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty == nil {
            if let activeSessionSummary {
                selectedSessionID = activeSessionSummary.id
            } else if let firstSession = sessions.first {
                selectedSessionID = firstSession.id
            }
        }
        showCompactComposer = true
        shouldFocusTextField = true
        Task { await onRefreshSessions?() }
        return true
    }

    func dismissCompactComposer() {
        showCompactComposer = false
        shouldFocusTextField = false
    }

    func startNewSessionFromCompactView() async {
        dismissDoneDetail()
        dismissWorkingDetail()
        showCompactComposer = true
        messageText = ""
        attachments.removeAll()
        await onNewSession?()
        shouldFocusTextField = true
    }

    var workingSummaryText: String? {
        if let detail = state.detail?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            return detail
        }
        if let hudDetail = workingToolActivity.first?.hudDetail?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            return hudDetail
        }
        if let detail = workingToolActivity.first?.detail?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            return detail
        }
        if let session = activeSessionSummary {
            return session.detail.nonEmpty ?? session.cwd?.nonEmpty
        }
        return nil
    }

    var workingPopupTitle: String {
        switch state.phase {
        case .listening:
            return "LISTENING"
        case .thinking, .acting:
            return "WORKING NOW"
        case .streaming:
            return "WRITING NOW"
        case .waitingForPermission:
            return "ACTION NEEDED"
        case .idle, .success, .failed:
            return "LIVE STATUS"
        }
    }

    private func shouldOfferWorkingDetail(for phase: AssistantHUDPhase) -> Bool {
        switch phase {
        case .listening, .thinking, .acting, .streaming:
            return true
        case .idle, .waitingForPermission, .success, .failed:
            return false
        }
    }

    private func clearTransientPopupsForNewTurn() {
        if showPlanDetail {
            storedProposedPlanText = nil
            showPlanDetail = false
        }
        if showDoneDetail {
            storedDoneDetailText = nil
            showDoneDetail = false
        }
        if showWorkingDetail {
            showWorkingDetail = false
        }
        if showCompactComposer {
            showCompactComposer = false
        }
    }

    func dismissDoneDetail() {
        showDoneDetail = false
        storedDoneDetailText = nil
    }

    func hideDoneDetail() {
        showDoneDetail = false
    }

    func showPreview(_ text: String) {
        storedDoneDetailText = text
        showDoneDetail = true
        storedProposedPlanText = nil
        showPlanDetail = false
        showCompactComposer = false
        Task { await onRefreshSessions?() }
    }

    func selectSessionForReply(_ session: AssistantSessionSummary) {
        selectedSessionID = session.id
        dismissPlanDetail()
        dismissDoneDetail()
        dismissCompactComposer()
    }

    func setInteractionMode(_ mode: AssistantInteractionMode) {
        guard interactionMode != mode else { return }
        interactionMode = mode
        onModeChanged?(mode)
    }

    var modeSwitchSuggestion: AssistantModeSwitchSuggestion? {
        if let controllerModeSwitchSuggestion,
           controllerModeSwitchSuggestion.originMode == interactionMode {
            return controllerModeSwitchSuggestion
        }

        return AssistantStore.modeSwitchSuggestion(
            forDraft: messageText,
            currentMode: interactionMode
        )
    }

    func cycleInteractionMode() {
        setInteractionMode(interactionMode.nextMode)
    }

    func showFollowUpPreview(for session: AssistantSessionSummary) {
        selectedSessionID = session.id
        dismissPlanDetail()
        dismissDoneDetail()
        dismissCompactComposer()
        guard let preview = session.latestAssistantMessage?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty else {
            isExpanded = true
            return
        }
        isExpanded = false
        showPreview(preview)
    }

    func updateLevel(_ level: Float) {
        let clamped = max(0, min(1, level))
        let smoothing: Float = clamped > self.level ? 0.24 : 0.14
        let next = self.level + ((clamped - self.level) * smoothing)
        self.level = max(0, min(1, next))
    }

    func expand() {
        isExpanded = true
        Task { await onRefreshSessions?() }
    }

    func collapseExpandedTray() {
        if isVoiceRecording {
            onStopVoiceRecording?()
            isVoiceRecording = false
        }
        isExpanded = false
        showCompactComposer = false
        shouldFocusTextField = false
        messageText = ""
    }

    func collapse() {
        collapseExpandedTray()
        dismissDoneDetail()
        dismissWorkingDetail()
    }

    func openSelectedSessionInMainWindow() {
        dismissWorkingDetail()
        dismissCompactComposer()
        guard let session = activeSessionSummary ?? sessions.first(where: { $0.id == selectedSessionID }) else {
            return
        }
        onOpenSession?(session)
    }

    func toggleExpanded() {
        if isExpanded { collapse() } else { expand() }
    }

    @discardableResult
    func handleOrbTap() -> OrbTapResult {
        if isExpanded {
            collapse()
            return .collapsedExpandedPanel
        }

        if showDoneDetail {
            dismissDoneDetail()
            return .dismissedDoneDetail
        }

        if showWorkingDetail {
            dismissWorkingDetail()
            return .dismissedWorkingDetail
        }

        if pendingPermissionRequest != nil {
            return .keptPermissionCardVisible
        }

        if modeSwitchSuggestion != nil {
            onDismissModeSwitchSuggestion?()
            return .dismissedModeSwitchSuggestion
        }

        if presentWorkingDetailIfAvailable() {
            return .presentedWorkingDetail
        }

        expand()
        return .expandedInlinePanel
    }

    /// Display name for the session that will receive the message.
    var targetSessionName: String? {
        guard let sid = selectedSessionID else { return nil }
        return sessions.first(where: { $0.id == sid })?.title.nonEmpty ?? "Selected session"
    }

    enum OrbTapResult: Equatable {
        case collapsedExpandedPanel
        case dismissedDoneDetail
        case dismissedWorkingDetail
        case keptPermissionCardVisible
        case dismissedModeSwitchSuggestion
        case presentedWorkingDetail
        case expandedInlinePanel
    }
}
