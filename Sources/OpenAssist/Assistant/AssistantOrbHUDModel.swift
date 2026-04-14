import AppKit
import Combine
import SwiftUI

private let kOrbPopupSizeKey = "assistantOrbPopupSize"

// MARK: - Model

@MainActor
final class AssistantOrbHUDModel: ObservableObject {
    @Published var state: AssistantHUDState = .idle
    @Published var level: Float = 0
    @Published var interactionMode: AssistantInteractionMode = .agentic {
        didSet {
            let normalizedMode = interactionMode.normalizedForActiveUse
            if interactionMode != normalizedMode {
                interactionMode = normalizedMode
                return
            }
            if oldValue != interactionMode { refreshCachedModeSwitchSuggestion() }
        }
    }
    @Published var busySessionID: String?

    // Expansion state
    @Published var isExpanded = false
    @Published var isLoadingSessions = false
    @Published var sessions: [AssistantSessionSummary] = []
    @Published var selectedSessionID: String?
    @Published var messageText = "" {
        didSet {
            if oldValue != messageText { scheduleModeSwitchRefresh() }
        }
    }
    @Published var attachments: [AssistantAttachment] = []
    @Published var shouldFocusTextField = false

    // Done detail popup
    @Published var showDoneDetail = false
    @Published private(set) var storedDoneDetailText: String?
    var doneDetailText: String? { storedDoneDetailText }
    @Published private(set) var storedPreviewImages: [Data] = []
    var previewImages: [Data] { storedPreviewImages }
    @Published private(set) var dismissedDoneDetailSignature: String?
    @Published var showPlanDetail = false
    @Published private(set) var storedProposedPlanText: String?
    var proposedPlanText: String? { storedProposedPlanText }

    // Live working detail popup
    @Published var showWorkingDetail = false
    @Published var showCompactComposer = false
    @Published var workingToolActivity: [AssistantToolCallState] = [] {
        didSet { refreshCachedWorkingSummary() }
    }
    @Published var activeSessionSummary: AssistantSessionSummary? {
        didSet { refreshCachedWorkingSummary() }
    }

    // Model selection
    @Published var visibleAssistantBackend: AssistantRuntimeBackend = .codex
    @Published var selectableAssistantBackends: [AssistantRuntimeBackend] = []
    @Published var isSelectedSessionBackendPinned = false
    @Published var selectedSessionBackendHelpText: String?
    @Published var availableModels: [AssistantModelOption] = []
    @Published var selectedModelSummary: String = ""
    @Published var runtimeControlsAvailability: AssistantRuntimeControlsAvailability = .ready
    @Published var runtimeControlsStatusText: String = ""
    @Published var controllerModeSwitchSuggestion: AssistantModeSwitchSuggestion? {
        didSet { refreshCachedModeSwitchSuggestion() }
    }
    @Published var canStopActiveTurn = false

    // Voice recording
    @Published var isVoiceRecording = false
    @Published var liveVoiceSnapshot = AssistantLiveVoiceSessionSnapshot()
    @Published var notchDockRevealed = false
    @Published var notchUsesHardwareOutline = false
    @Published var notchHardwareOutlineSize: NSSize = .zero
    @Published var notchDockVisibleWidth: CGFloat = 160
    @Published var notchDockVisibleHeight: CGFloat = 4

    // Popup size (user-resizable, persisted)
    @Published var popupSize: NSSize = Layout.defaultPopupSize

    // Cached computed values — avoids recomputation on every view body evaluation.
    @Published private(set) var modeSwitchSuggestion: AssistantModeSwitchSuggestion?
    @Published private(set) var cachedWorkingSummaryText: String?
    private var modeSwitchDebounceWorkItem: DispatchWorkItem?

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
    var onOpenMainWindow: (() -> Void)?
    var onNewSession: (() async -> Void)?
    var onNewTemporarySession: (() async -> Void)?
    var onPromoteTemporarySession: ((String?) -> Void)?
    var onChooseBackend: ((AssistantRuntimeBackend) -> Void)?
    var onChooseModel: ((String) -> Void)?
    var onOpenAttachmentPicker: (() -> Void)?
    var onAddAttachment: ((AssistantAttachment) -> Void)?
    var onRemoveAttachment: ((UUID) -> Void)?
    var onStartLiveVoiceSession: (() -> Void)?
    var onEndLiveVoiceSession: (() -> Void)?
    var onStopLiveVoiceSpeaking: (() -> Void)?
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
        let trimmedDetail = state.detail?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let completionSignature = doneDetailSignature(for: trimmedDetail)
        let shouldSuppressRepeatedCompletion =
            (state.phase == .success || state.phase == .failed)
            && completionSignature != nil
            && completionSignature == dismissedDoneDetailSignature

        self.state = shouldSuppressRepeatedCompletion ? .idle : state
        refreshCachedWorkingSummary()

        switch self.state.phase {
        case .success, .failed:
            storedPreviewImages = []
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
            dismissedDoneDetailSignature = nil
            storedDoneDetailText = nil
            storedPreviewImages = []
            showDoneDetail = false
            showWorkingDetail = false
            showCompactComposer = false
            shouldFocusTextField = false
        case .listening, .thinking, .acting, .streaming:
            dismissedDoneDetailSignature = nil
            storedDoneDetailText = nil
            storedPreviewImages = []
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

    func startNewTemporarySessionFromCompactView() async {
        dismissDoneDetail()
        dismissWorkingDetail()
        showCompactComposer = true
        messageText = ""
        attachments.removeAll()
        await onNewTemporarySession?()
        shouldFocusTextField = true
    }

    var selectedSessionSummary: AssistantSessionSummary? {
        if let selectedSessionID = selectedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            if let matchingSession = sessions.first(where: {
                $0.id.caseInsensitiveCompare(selectedSessionID) == .orderedSame
            }) {
                return matchingSession
            }
            if let activeSessionSummary,
               activeSessionSummary.id.caseInsensitiveCompare(selectedSessionID) == .orderedSame {
                return activeSessionSummary
            }
        }

        if let activeSessionSummary {
            return activeSessionSummary
        }

        return sessions.first
    }

    var selectedSessionIsTemporary: Bool {
        selectedSessionSummary?.isTemporary == true
    }

    func promoteSelectedTemporarySession() {
        guard selectedSessionIsTemporary else { return }
        onPromoteTemporarySession?(selectedSessionSummary?.id ?? selectedSessionID)
    }

    var workingSummaryText: String? { cachedWorkingSummaryText }

    private func refreshCachedWorkingSummary() {
        let next = computeWorkingSummaryText()
        if next != cachedWorkingSummaryText { cachedWorkingSummaryText = next }
    }

    private func computeWorkingSummaryText() -> String? {
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
        dismissedDoneDetailSignature = doneDetailSignature(for: storedDoneDetailText)
        showDoneDetail = false
        storedDoneDetailText = nil
        storedPreviewImages = []
    }

    func hideDoneDetail() {
        dismissDoneDetail()
    }

    func showPreview(_ text: String) {
        dismissedDoneDetailSignature = nil
        storedDoneDetailText = text
        showDoneDetail = true
        storedProposedPlanText = nil
        showPlanDetail = false
        showCompactComposer = false
        Task { await onRefreshSessions?() }
    }

    func updatePreviewImages(_ images: [Data]) {
        if storedPreviewImages != images {
            storedPreviewImages = images
        }
        if storedDoneDetailText == nil,
           !images.isEmpty,
           dismissedDoneDetailSignature == nil,
           storedProposedPlanText?.nonEmpty == nil,
           state.phase == .success || state.phase == .failed {
            if !showDoneDetail {
                showDoneDetail = true
            }
        }
    }

    func selectSessionForReply(_ session: AssistantSessionSummary) {
        selectedSessionID = session.id
        dismissPlanDetail()
        dismissDoneDetail()
        dismissCompactComposer()
    }

    func setInteractionMode(_ mode: AssistantInteractionMode) {
        let normalizedMode = mode.normalizedForActiveUse
        guard interactionMode != normalizedMode else { return }
        interactionMode = normalizedMode
        onModeChanged?(normalizedMode)
    }

    private func refreshCachedModeSwitchSuggestion() {
        modeSwitchDebounceWorkItem?.cancel()
        let next: AssistantModeSwitchSuggestion?
        if let controllerModeSwitchSuggestion,
           controllerModeSwitchSuggestion.originMode == interactionMode {
            next = controllerModeSwitchSuggestion
        } else {
            next = AssistantStore.modeSwitchSuggestion(
                forDraft: messageText,
                currentMode: interactionMode
            )
        }
        if next != modeSwitchSuggestion { modeSwitchSuggestion = next }
    }

    /// Debounce mode-switch re-evaluation while the user is typing.
    /// Clears the stale suggestion immediately (so UI stops showing an outdated card)
    /// but delays the potentially-expensive recomputation by 0.3 s.
    private func scheduleModeSwitchRefresh() {
        modeSwitchDebounceWorkItem?.cancel()
        // If the current suggestion is draft-based and the text changed, clear it now.
        if modeSwitchSuggestion?.source == .draft { modeSwitchSuggestion = nil }
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.refreshCachedModeSwitchSuggestion() }
        }
        modeSwitchDebounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Force an immediate (non-debounced) mode-switch evaluation.
    /// Useful after programmatic text changes or in tests.
    func flushModeSwitchSuggestion() {
        modeSwitchDebounceWorkItem?.cancel()
        refreshCachedModeSwitchSuggestion()
    }

    var isLiveVoiceActive: Bool {
        liveVoiceSnapshot.isActive
    }

    var isLiveVoiceListening: Bool {
        liveVoiceSnapshot.isListening
    }

    var isLiveVoiceSpeaking: Bool {
        liveVoiceSnapshot.isSpeaking
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
            // No session available — still open the main assistant window
            collapse()
            onOpenMainWindow?()
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

    private func doneDetailSignature(for text: String?) -> String? {
        guard let normalizedText = text?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return nil
        }

        let sessionID = selectedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            ?? activeSessionSummary?.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            ?? ""

        return "\(sessionID)|\(normalizedText)"
    }
}
