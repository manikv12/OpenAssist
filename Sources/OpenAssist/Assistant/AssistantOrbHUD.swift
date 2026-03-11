import AppKit
import Combine
import MarkdownUI
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

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

    // Live working detail popup
    @Published var showWorkingDetail = false
    @Published var workingToolActivity: [AssistantToolCallState] = []
    @Published var activeSessionSummary: AssistantSessionSummary?

    // Model selection
    @Published var availableModels: [AssistantModelOption] = []
    @Published var selectedModelSummary: String = ""
    @Published var controllerModeSwitchSuggestion: AssistantModeSwitchSuggestion?

    // Voice recording
    @Published var isVoiceRecording = false

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
    var onResolvePermission: ((String) -> Void)?
    var onCancelPermission: (() -> Void)?
    var onAlwaysAllowPermission: ((String) -> Void)?
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
            showDoneDetail = trimmedDetail != nil
            showWorkingDetail = false
        case .idle:
            // Keep the completion/error popup visible until the user closes it.
            showWorkingDetail = false
            break
        case .waitingForPermission:
            storedDoneDetailText = nil
            showDoneDetail = false
            showWorkingDetail = false
        case .listening, .thinking, .acting, .streaming:
            storedDoneDetailText = nil
            showDoneDetail = false
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
        return true
    }

    func dismissWorkingDetail() {
        showWorkingDetail = false
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
        if showDoneDetail {
            storedDoneDetailText = nil
            showDoneDetail = false
        }
        if showWorkingDetail {
            showWorkingDetail = false
        }
    }

    func dismissDoneDetail() {
        showDoneDetail = false
        storedDoneDetailText = nil
    }

    func showPreview(_ text: String) {
        storedDoneDetailText = text
        showDoneDetail = true
    }

    func selectSessionForReply(_ session: AssistantSessionSummary) {
        selectedSessionID = session.id
        dismissDoneDetail()
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
        dismissDoneDetail()
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

    func collapse() {
        if isVoiceRecording {
            onStopVoiceRecording?()
            isVoiceRecording = false
        }
        isExpanded = false
        dismissDoneDetail()
        dismissWorkingDetail()
        shouldFocusTextField = false
        messageText = ""
    }

    func openSelectedSessionInMainWindow() {
        dismissWorkingDetail()
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

// MARK: - Manager

private let kOrbPositionKey = "assistantOrbHUDPosition"
private let kOrbPopupSizeKey = "assistantOrbPopupSize"

@MainActor
final class AssistantOrbHUDManager {
    private enum Layout {
        static let collapsedSize = NSSize(width: 140, height: 156)
        static let expandedSize = AssistantOrbHUDModel.Layout.expandedSize
    }

    private let model = AssistantOrbHUDModel()
    private let controller: AssistantStore
    private var panel: OrbHUDPanel?
    private var cancellables = Set<AnyCancellable>()
    private var clickOutsideMonitor: Any?

    /// Saved orb origin (bottom-left of collapsed frame). `nil` = use default center position.
    private var savedOrigin: NSPoint?

    var isEnabled = true {
        didSet {
            if !isEnabled { hide() }
        }
    }

    func showFollowUp(for session: AssistantSessionSummary) {
        guard isEnabled else { return }
        if panel == nil { createPanel() }

        controller.selectedSessionID = session.id
        syncModelFromController()
        model.showFollowUpPreview(for: session)

        if !model.isExpanded {
            reposition()
        }
        panel?.orderFrontRegardless()
    }

    private var autoDismissItem: DispatchWorkItem?

    init(controller: AssistantStore) {
        self.controller = controller

        // Restore saved position
        if let dict = UserDefaults.standard.dictionary(forKey: kOrbPositionKey),
           let x = dict["x"] as? Double, let y = dict["y"] as? Double {
            savedOrigin = NSPoint(x: x, y: y)
        }

        // HUD state from runtime
        controller.$hudState
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                self?.syncModelFromController()
                self?.update(state: state)
            }
            .store(in: &cancellables)

        controller.$interactionMode
            .receive(on: RunLoop.main)
            .sink { [weak self] mode in
                self?.model.interactionMode = mode
            }
            .store(in: &cancellables)

        controller.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] sessions in
                self?.model.sessions = sessions
                self?.syncModelFromController()
            }
            .store(in: &cancellables)

        controller.$selectedSessionID
            .receive(on: RunLoop.main)
            .sink { [weak self] selectedSessionID in
                self?.model.selectedSessionID = selectedSessionID
                self?.syncModelFromController()
            }
            .store(in: &cancellables)

        controller.$attachments
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncModelFromController() }
            .store(in: &cancellables)

        controller.$availableModels
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncModelFromController() }
            .store(in: &cancellables)

        controller.$selectedModelID
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncModelFromController() }
            .store(in: &cancellables)

        controller.$toolCalls
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncModelFromController() }
            .store(in: &cancellables)

        controller.$recentToolCalls
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncModelFromController() }
            .store(in: &cancellables)

        // Resize panel when expansion toggles
        model.$isExpanded
            .receive(on: RunLoop.main)
            .sink { [weak self] expanded in
                self?.handleExpansionChange(expanded)
            }
            .store(in: &cancellables)

        // Resize panel when done detail popup toggles.
        // Must fire synchronously (no `.receive(on:)`) so the panel
        // frame updates in the same run-loop tick as the SwiftUI view,
        // preventing the orb from jumping during dismiss.
        model.$showDoneDetail
            .sink { [weak self] showing in
                self?.handleDoneDetailChange(showing)
            }
            .store(in: &cancellables)

        model.$showWorkingDetail
            .sink { [weak self] showing in
                self?.handleWorkingDetailChange(showing)
            }
            .store(in: &cancellables)

        // Reposition panel when popup is resized by the user
        model.$popupSize
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, !self.model.isExpanded else { return }
                self.reposition()
            }
            .store(in: &cancellables)

        // Wire model callbacks
        model.onRefreshSessions = { [weak self] in
            await self?.refreshSessionsForOrb()
        }

        model.onSendMessage = { [weak self] message, sessionID in
            self?.sendMessageFromOrb(message, sessionID: sessionID)
        }

        model.onSessionSelected = { [weak self] session in
            Task { @MainActor in
                await self?.controller.openSession(session)
            }
        }

        model.onOpenSession = { [weak self] session in
            Task { @MainActor in
                await self?.controller.openSession(session)
                self?.model.collapse()
                NotificationCenter.default.post(name: .openAssistOpenAssistant, object: nil)
            }
        }

        model.onNewSession = { [weak self] in
            await self?.controller.startNewSession()
            await self?.refreshSessionsForOrb()
        }

        model.onChooseModel = { [weak self] modelID in
            self?.controller.chooseModel(modelID)
            self?.syncModelFromController()
        }

        model.onOpenAttachmentPicker = { [weak self] in
            AssistantAttachmentSupport.openFilePicker { attachments in
                guard let self, !attachments.isEmpty else { return }
                self.controller.attachments.append(contentsOf: attachments)
                self.syncModelFromController()
            }
        }

        model.onAddAttachment = { [weak self] attachment in
            guard let self else { return }
            self.controller.attachments.append(attachment)
            self.syncModelFromController()
        }

        model.onRemoveAttachment = { [weak self] attachmentID in
            guard let self else { return }
            self.controller.attachments.removeAll { $0.id == attachmentID }
            self.syncModelFromController()
        }

        model.onModeChanged = { [weak self] mode in
            self?.controller.interactionMode = mode
            self?.controller.syncRuntimeContext()
        }

        model.onApplyModeSwitchSuggestion = { [weak self] choice in
            guard let self else { return }
            Task { @MainActor in
                await self.controller.applyModeSwitchSuggestion(choice)
                self.syncModelFromController()
            }
        }

        model.onDismissModeSwitchSuggestion = { [weak self] in
            self?.controller.dismissModeSwitchSuggestion()
            self?.syncModelFromController()
        }

        model.onStartVoiceRecording = { [weak self] in
            self?.model.isVoiceRecording = true
            NotificationCenter.default.post(name: .openAssistStartOrbVoiceCapture, object: nil)
        }

        model.onStopVoiceRecording = { [weak self] in
            self?.model.isVoiceRecording = false
            NotificationCenter.default.post(name: .openAssistStopOrbVoiceCapture, object: nil)
        }

        model.onResolvePermission = { [weak self] optionID in
            guard let self else { return }
            Task { await self.controller.resolvePermission(optionID: optionID) }
        }

        model.onCancelPermission = { [weak self] in
            guard let self else { return }
            Task { await self.controller.cancelPermissionRequest() }
        }

        model.onAlwaysAllowPermission = { [weak self] toolKind in
            self?.controller.alwaysAllowToolKind(toolKind)
        }

        // Permission request from controller
        controller.$pendingPermissionRequest
            .receive(on: RunLoop.main)
            .sink { [weak self] request in
                self?.model.pendingPermissionRequest = request
                self?.handlePermissionRequestChange(request)
            }
            .store(in: &cancellables)

        controller.$modeSwitchSuggestion
            .receive(on: RunLoop.main)
            .sink { [weak self] suggestion in
                self?.model.controllerModeSwitchSuggestion = suggestion
                self?.handleModeSwitchSuggestionChange(suggestion)
            }
            .store(in: &cancellables)

        syncModelFromController()

        // Show the orb immediately on launch
        if isEnabled {
            show(state: .idle)
        }
    }

    // MARK: Public

    func show(state: AssistantHUDState) {
        if panel == nil { createPanel() }
        guard let panel else { return }
        model.update(state: displayState(for: state))
        if !panel.isVisible || panel.frame.size != targetSize {
            reposition()
        }
        panel.orderFrontRegardless()
    }

    func update(state: AssistantHUDState) {
        autoDismissItem?.cancel()
        autoDismissItem = nil

        guard isEnabled, shouldPresent(state) else {
            if !model.isExpanded { hide() }
            return
        }

        if let detail = state.detail, !detail.isEmpty {
            if state.phase == .success, model.state.phase != .success {
                sendCompletionNotification(message: detail)
            } else if state.phase == .failed, model.state.phase != .failed {
                sendCompletionNotification(message: detail)
            }
        }

        show(state: state)
    }

    func updateLevel(_ level: Float) {
        model.updateLevel(level)
    }

    func setVoiceRecording(_ isRecording: Bool) {
        model.isVoiceRecording = isRecording
        if !isRecording {
            model.updateLevel(0)
        }
    }

    func receiveVoiceTranscript(_ text: String) {
        model.isVoiceRecording = false
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, !AssistantComposerBridge.shared.insert(trimmed) {
            model.messageText = trimmed
        }
        model.updateLevel(0)
    }

    func hide() {
        model.collapse()
        model.update(state: .idle)
        model.updateLevel(0)
        stopClickOutsideMonitor()
        panel?.orderOut(nil)
    }

    /// Resets the orb to idle appearance without hiding it.
    private func resetToIdle() {
        guard !model.isExpanded else { return }
        model.update(state: .idle)
        model.updateLevel(0)
    }

    // MARK: Private

    private func shouldPresent(_ state: AssistantHUDState) -> Bool {
        return true
    }

    private func createPanel() {
        let panel = OrbHUDPanel(
            contentRect: NSRect(origin: .zero, size: Layout.collapsedSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = false
        panel.onPositionPersist = { [weak self] in
            guard let self, let panel = self.panel else { return }
            self.persistCollapsedOrigin(
                from: panel.frame.origin,
                panelSize: panel.frame.size
            )
        }
        panel.contentViewController = NSHostingController(rootView: AssistantOrbHUDView(model: model))
        self.panel = panel
    }

    private var targetSize: NSSize {
        if model.isExpanded { return Layout.expandedSize }
        if model.showDoneDetail
            || model.showWorkingDetail
            || model.pendingPermissionRequest != nil
            || model.modeSwitchSuggestion != nil {
            return model.popupSize
        }
        return Layout.collapsedSize
    }

    private func reposition() {
        guard let panel else { return }
        let screen = screenForCurrentPlacement(panel: panel)
        guard let screen else { return }

        let availableFrame = screen.visibleFrame
        let requestedSize = targetSize
        let size = NSSize(
            width: min(requestedSize.width, availableFrame.width),
            height: min(requestedSize.height, availableFrame.height)
        )

        panel.isOrbAnchoredAtBottom = isOrbAnchoredAtBottom

        let origin: NSPoint
        if let saved = savedOrigin {
            if requestedSize != Layout.collapsedSize {
                // Keep the orb centered on the same user-placed x position.
                let orbCenterX = saved.x + Layout.collapsedSize.width / 2
                origin = NSPoint(
                    x: orbCenterX - size.width / 2,
                    y: isOrbAnchoredAtBottom
                        ? saved.y
                        : saved.y + Layout.collapsedSize.height - size.height
                )
            } else {
                origin = saved
            }
        } else {
            // Default: center on screen near bottom.
            let x = availableFrame.midX - (size.width / 2)
            let y = availableFrame.minY + 36
            origin = NSPoint(x: x, y: y)
        }

        let clampedX = max(availableFrame.minX, min(origin.x, availableFrame.maxX - size.width))
        let clampedY = max(availableFrame.minY, min(origin.y, availableFrame.maxY - size.height))
        let frame = NSRect(origin: NSPoint(x: clampedX, y: clampedY), size: size)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.setFrame(frame, display: true, animate: false)
        CATransaction.commit()

        if savedOrigin == nil {
            persistCollapsedOrigin(from: frame.origin, panelSize: size)
        }
    }

    private func handleDoneDetailChange(_ showing: Bool) {
        if !model.isExpanded {
            reposition()
        }
        if showing {
            if !model.isExpanded {
                activatePopupTextEntry()
                startClickOutsideMonitor()
            }
        } else {
            if !model.isExpanded {
                deactivatePopupTextEntry()
                stopClickOutsideMonitor()
            }
            // When the user dismisses the detail, reset the orb to idle
            // so it doesn't stay stuck showing the "DONE" or error state.
            if model.state.phase == .success || model.state.phase == .failed {
                resetToIdle()
            }
        }
    }

    private func handleWorkingDetailChange(_ showing: Bool) {
        if !model.isExpanded {
            reposition()
        }
        if showing {
            if !model.isExpanded {
                activatePopupTextEntry()
                startClickOutsideMonitor()
            }
        } else if !model.isExpanded {
            deactivatePopupTextEntry()
            stopClickOutsideMonitor()
        }
    }

    private func handlePermissionRequestChange(_ request: AssistantPermissionRequest?) {
        guard !model.isExpanded else { return }
        reposition()
        if request != nil {
            if panel == nil { createPanel() }
            panel?.orderFrontRegardless()
            startClickOutsideMonitor()
        } else {
            stopClickOutsideMonitor()
        }
    }

    private func handleModeSwitchSuggestionChange(_ suggestion: AssistantModeSwitchSuggestion?) {
        guard !model.isExpanded else { return }
        reposition()
        if suggestion != nil {
            if panel == nil { createPanel() }
            panel?.orderFrontRegardless()
            startClickOutsideMonitor()
        } else if model.pendingPermissionRequest == nil && !model.showDoneDetail && !model.showWorkingDetail {
            stopClickOutsideMonitor()
        }
    }

    private func handleExpansionChange(_ expanded: Bool) {
        reposition()
        if expanded {
            panel?.allowsKeyStatus = true
            panel?.makeKeyAndOrderFront(nil)
            startClickOutsideMonitor()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.model.shouldFocusTextField = true
            }
        } else {
            model.shouldFocusTextField = false
            panel?.allowsKeyStatus = false
            stopClickOutsideMonitor()
        }
    }

    private func startClickOutsideMonitor() {
        stopClickOutsideMonitor()
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.model.isExpanded || self.model.showDoneDetail || self.model.showWorkingDetail else { return }
                if let panel = self.panel, panel.frame.contains(NSEvent.mouseLocation) {
                    return
                }
                if self.model.isExpanded {
                    self.model.collapse()
                } else if self.model.showDoneDetail {
                    self.model.dismissDoneDetail()
                } else {
                    self.model.dismissWorkingDetail()
                }
            }
        }
    }

    private func stopClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }

    private func activatePopupTextEntry() {
        guard !model.isExpanded else { return }
        if panel == nil { createPanel() }
        panel?.allowsKeyStatus = true
        panel?.makeKeyAndOrderFront(nil)
        model.shouldFocusTextField = false
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.model.isExpanded else { return }
            guard self.model.showDoneDetail || self.model.showWorkingDetail else { return }
            self.model.shouldFocusTextField = true
        }
    }

    private func deactivatePopupTextEntry() {
        guard !model.isExpanded else { return }
        model.shouldFocusTextField = false
        panel?.allowsKeyStatus = false
    }

    private func refreshSessionsForOrb() async {
        syncModelFromController()

        model.isLoadingSessions = model.sessions.isEmpty

        if controller.visibleModels.isEmpty {
            await controller.refreshEnvironment()
        }

        await controller.refreshSessions()
        syncModelFromController()
        model.isLoadingSessions = false
    }

    private func sendMessageFromOrb(_ message: String, sessionID: String?) {
        Task { @MainActor in
            if let sessionID {
                if let session = controller.sessions.first(where: { self.sessionIDsMatch($0.id, sessionID) }) {
                    await controller.openSession(session)
                } else {
                    controller.selectedSessionID = sessionID
                }
            }
            controller.interactionMode = model.interactionMode
            if controller.hasActiveTurn {
                await controller.cancelActiveTurn()
            }
            await controller.sendPrompt(message)
            await controller.refreshSessions()
            self.syncModelFromController()
        }
    }

    private func syncModelFromController() {
        model.sessions = controller.sessions
        model.selectedSessionID = controller.selectedSessionID
        model.interactionMode = controller.interactionMode
        model.busySessionID = activeSessionIDForOrb()
        model.availableModels = controller.visibleModels
        model.selectedModelSummary = controller.selectedModelSummary
        model.attachments = controller.attachments
        model.controllerModeSwitchSuggestion = controller.modeSwitchSuggestion
        model.workingToolActivity = Array(controller.visibleToolActivity.prefix(6))
        model.activeSessionSummary = activeSessionSummaryForOrb()
        model.update(state: displayState(for: model.state))
    }

    private func activeSessionIDForOrb() -> String? {
        guard shouldShowBusyIndicator(for: controller.hudState.phase) else {
            return nil
        }
        return controller.activeRuntimeSessionID ?? controller.selectedSessionID
    }

    private func shouldShowBusyIndicator(for phase: AssistantHUDPhase) -> Bool {
        switch phase {
        case .listening, .thinking, .acting, .waitingForPermission, .streaming:
            return true
        case .idle, .success, .failed:
            return false
        }
    }

    private func displayState(for state: AssistantHUDState) -> AssistantHUDState {
        guard state.phase == .success else { return state }
        guard state.detail?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty == nil,
              let preview = latestAssistantPreview()?.nonEmpty else {
            return state
        }

        return AssistantHUDState(
            phase: state.phase,
            title: "Reply ready",
            detail: preview
        )
    }

    private func latestAssistantPreview() -> String? {
        let preferredSessionID = controller.activeRuntimeSessionID ?? controller.selectedSessionID

        if let preferredSessionID,
           let session = controller.sessions.first(where: { sessionIDsMatch($0.id, preferredSessionID) }),
           let preview = session.latestAssistantMessage?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            return preview
        }

        return controller.sessions.first?.latestAssistantMessage?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    private func activeSessionSummaryForOrb() -> AssistantSessionSummary? {
        let preferredSessionID = controller.activeRuntimeSessionID ?? controller.selectedSessionID

        if let preferredSessionID,
           let session = controller.sessions.first(where: { sessionIDsMatch($0.id, preferredSessionID) }) {
            return session
        }

        return controller.sessions.first
    }

    private func sessionIDsMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs = lhs?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
              let rhs = rhs?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return false
        }
        return lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }

    private func persistCollapsedOrigin(from panelOrigin: NSPoint, panelSize: NSSize) {
        let collapsedOrigin: NSPoint
        if panelSize.width > Layout.collapsedSize.width || panelSize.height > Layout.collapsedSize.height {
            let collapsedX = panelOrigin.x + ((panelSize.width - Layout.collapsedSize.width) / 2)
            let collapsedY = isOrbAnchoredAtBottom
                ? panelOrigin.y
                : panelOrigin.y + (panelSize.height - Layout.collapsedSize.height)
            collapsedOrigin = NSPoint(x: collapsedX, y: collapsedY)
        } else {
            collapsedOrigin = panelOrigin
        }

        savedOrigin = collapsedOrigin
        let dict: [String: Double] = [
            "x": Double(collapsedOrigin.x),
            "y": Double(collapsedOrigin.y)
        ]
        UserDefaults.standard.set(dict, forKey: kOrbPositionKey)
    }

    private var isOrbAnchoredAtBottom: Bool {
        model.isExpanded
            || model.showDoneDetail
            || model.showWorkingDetail
            || model.pendingPermissionRequest != nil
            || model.modeSwitchSuggestion != nil
    }

    private func screenForCurrentPlacement(panel: NSPanel) -> NSScreen? {
        if let panelScreen = panel.screen {
            return panelScreen
        }

        if let saved = savedOrigin {
            let collapsedFrame = NSRect(origin: saved, size: Layout.collapsedSize)
            if let matchingScreen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(collapsedFrame) }) {
                return matchingScreen
            }
        }

        return NSScreen.main ?? NSScreen.screens.first
    }

    private func sendCompletionNotification(message: String) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Open Assist Assistant"
            content.body = message
            content.sound = .default
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }
}

// MARK: - Key-capable Panel with native drag

private class OrbHUDPanel: NSPanel {
    var allowsKeyStatus = false
    var onPositionPersist: (() -> Void)?
    /// When true, the orb sits at the bottom of the panel. Drag zone moves to bottom.
    var isOrbAnchoredAtBottom = false

    /// Height of the orb area that initiates dragging.
    private let orbAreaHeight: CGFloat = 120
    private let dragThreshold: CGFloat = 4

    private var dragStartScreenLocation: NSPoint?
    private var dragStartOrigin: NSPoint?
    private var isWindowDragging = false

    override var canBecomeKey: Bool { allowsKeyStatus }

    /// Check if click is in the orb drag zone.
    /// When the orb is bottom-anchored, drag from the lower orb area.
    /// Otherwise, drag from the upper orb area.
    private func isInOrbDragZone(_ loc: NSPoint) -> Bool {
        if isOrbAnchoredAtBottom {
            // Orb is at the bottom — drag from the lower orbAreaHeight
            return loc.y <= orbAreaHeight
        } else {
            // Orb is at the top — drag from the upper orbAreaHeight
            return loc.y >= frame.height - orbAreaHeight
        }
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            let loc = event.locationInWindow
            if isInOrbDragZone(loc) {
                dragStartScreenLocation = NSEvent.mouseLocation
                dragStartOrigin = frame.origin
                isWindowDragging = false
            }
            super.sendEvent(event)

        case .leftMouseDragged:
            guard let startLoc = dragStartScreenLocation,
                  let startOrigin = dragStartOrigin else {
                super.sendEvent(event)
                return
            }

            let currentLoc = NSEvent.mouseLocation
            let dx = currentLoc.x - startLoc.x
            let dy = currentLoc.y - startLoc.y

            if !isWindowDragging {
                if abs(dx) > dragThreshold || abs(dy) > dragThreshold {
                    isWindowDragging = true
                } else {
                    return // Below threshold, swallow to avoid jitter
                }
            }

            // Move window using screen-space delta (window-server level, zero latency)
            setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
            // Don't pass to super — we own this gesture now

        case .leftMouseUp:
            if isWindowDragging {
                onPositionPersist?()
                isWindowDragging = false
                dragStartScreenLocation = nil
                dragStartOrigin = nil
                return // Consumed by drag, don't forward as tap
            }
            dragStartScreenLocation = nil
            dragStartOrigin = nil
            super.sendEvent(event)

        case .rightMouseDown:
            let loc = event.locationInWindow
            if isInOrbDragZone(loc) {
                showOrbContextMenu(at: event)
                return
            }
            super.sendEvent(event)

        default:
            super.sendEvent(event)
        }
    }

    private func showOrbContextMenu(at event: NSEvent) {
        let menu = NSMenu()
        let quitItem = NSMenuItem(title: "Quit Open Assist", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
        NSMenu.popUpContextMenu(menu, with: event, for: contentView!)
    }
}

// MARK: - HUD View

private struct AssistantOrbHUDView: View {
    @ObservedObject var model: AssistantOrbHUDModel
    @State private var resizeStartSize: NSSize?
    @State private var previewAttachment: AssistantAttachment?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum OrbHUDAnimations {
        static let state = Animation.easeInOut(duration: 0.22)
        static let content = Animation.easeOut(duration: 0.18)
    }

    private let overlayBottomDock: CGFloat = 108

    private var showingPopup: Bool {
        (
            model.showDoneDetail
            || model.showWorkingDetail
            || model.pendingPermissionRequest != nil
            || model.modeSwitchSuggestion != nil
        ) && !model.isExpanded
    }

    /// The popup content area height = total popup height minus the orb section (156pt).
    private var popupContentMaxHeight: CGFloat {
        model.popupSize.height - 156
    }

    private var expandedSessionListMaxHeight: CGFloat {
        216
    }

    private var overlayContentMaxHeight: CGFloat {
        let totalHeight = model.isExpanded
            ? AssistantOrbHUDModel.Layout.expandedSize.height
            : model.popupSize.height
        return max(180, totalHeight - overlayBottomDock)
    }

    private var resizeHandle: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 6)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if resizeStartSize == nil { resizeStartSize = model.popupSize }
                        guard let start = resizeStartSize else { return }
                        // Dragging up (negative y in SwiftUI) → increase height
                        let newHeight = start.height - value.translation.height
                        let clamped = min(
                            max(newHeight, AssistantOrbHUDModel.Layout.minPopupSize.height),
                            AssistantOrbHUDModel.Layout.maxPopupSize.height
                        )
                        model.popupSize.height = clamped
                    }
                    .onEnded { _ in
                        resizeStartSize = nil
                        model.persistPopupSize()
                    }
            )
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            overlayContent
            orbSection
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .frame(
            width: model.isExpanded ? AssistantOrbHUDModel.Layout.expandedSize.width : (showingPopup ? model.popupSize.width : 140),
            height: model.isExpanded ? AssistantOrbHUDModel.Layout.expandedSize.height : (showingPopup ? model.popupSize.height : 156),
            alignment: .bottom
        )
        .popover(item: $previewAttachment, attachmentAnchor: .point(.center)) { attachment in
            if let nsImage = NSImage(data: attachment.data) {
                VStack {
                    HStack {
                        Spacer()
                        Button {
                            previewAttachment = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .padding(8)
                    }
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 720, maxHeight: 520)
                        .padding([.bottom, .horizontal])
                }
                .frame(minWidth: 360, minHeight: 260)
            }
        }
    }

    @ViewBuilder
    private var overlayContent: some View {
        if model.isExpanded {
            sessionPopoverSection
                .frame(maxHeight: overlayContentMaxHeight)
                .padding(.bottom, overlayBottomDock)
                .transition(.opacity)
        } else if model.showDoneDetail {
            VStack(spacing: 0) {
                resizeHandle
                doneDetailPopup(maxHeight: overlayContentMaxHeight, showsFollowUpComposer: true)
            }
            .padding(.bottom, overlayBottomDock)
            .transition(.opacity)
        } else if model.showWorkingDetail && !model.showDoneDetail && model.pendingPermissionRequest == nil {
            VStack(spacing: 0) {
                resizeHandle
                workingDetailPopup(maxHeight: overlayContentMaxHeight)
            }
            .padding(.bottom, overlayBottomDock)
            .transition(.opacity)
        } else if model.pendingPermissionRequest != nil && !model.showDoneDetail && !model.showWorkingDetail {
            VStack(spacing: 0) {
                resizeHandle
                permissionPopup(maxHeight: overlayContentMaxHeight)
            }
            .padding(.bottom, overlayBottomDock)
            .transition(.opacity)
        } else if model.modeSwitchSuggestion != nil
            && !model.showDoneDetail
            && !model.showWorkingDetail
            && model.pendingPermissionRequest == nil {
            VStack(spacing: 0) {
                resizeHandle
                modeSwitchPopup(maxHeight: overlayContentMaxHeight)
            }
            .padding(.bottom, overlayBottomDock)
            .transition(.opacity)
        }
    }

    // MARK: Orb

    private var orbSection: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                glowColor.opacity(0.20),
                                glowColor.opacity(0.10),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: 8,
                            endRadius: 42
                        )
                    )
                    .frame(width: 90, height: 90)
                    .blur(radius: 12)
                    .opacity(reduceMotion ? 0.85 : 1.0)

                orbSphereView
            }
            .frame(height: 72)
            .onTapGesture { handleOrbTap() }
            .onHover { hovering in
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }

            VStack(spacing: 3.5) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(glowColor.opacity(0.92))
                        .frame(width: 5, height: 5)

                    Text(phaseLabel)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .tracking(0.9)
                        .textCase(.uppercase)
                        .foregroundStyle(.white.opacity(0.94))
                        .contentTransition(.opacity)
                }

                if let detail = model.state.detail, !detail.isEmpty, !model.showDoneDetail, !model.showWorkingDetail {
                    Text(detail)
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(2)
                        .truncationMode(model.state.phase == .success ? .tail : .middle)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 136)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(OrbStatusCapsuleBackground(tint: glowColor))
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(0.07), lineWidth: 0.5)
            )
            .animation(OrbHUDAnimations.content, value: model.state.detail)
            .animation(OrbHUDAnimations.state, value: model.state.phase)
        }
        .padding(.top, 12)
        .frame(maxWidth: .infinity)
        .frame(height: 156, alignment: .top)
    }

    private var orbSphereView: some View {
        let paused = model.state.phase == .idle
        return TimelineView(.animation(minimumInterval: orbRefreshInterval, paused: paused)) { context in
            OrbSphere(
                phase: model.state.phase,
                level: CGFloat(model.level),
                time: context.date.timeIntervalSinceReferenceDate
            )
            .frame(width: 64, height: 64)
        }
    }

    private var orbRefreshInterval: Double {
        switch model.state.phase {
        case .listening, .acting, .streaming:
            return 1.0 / 24.0
        case .thinking, .waitingForPermission, .failed:
            return 1.0 / 18.0
        case .idle, .success:
            return 1.0 / 12.0
        }
    }

    // MARK: Done Detail Popup

    private func doneDetailPopup(maxHeight: CGFloat, showsFollowUpComposer: Bool) -> some View {
        let tint = Color(red: 0.20, green: 0.84, blue: 0.46)

        return VStack(spacing: 0) {
            OrbPopupHeader(
                title: "Done",
                subtitle: "Latest assistant result",
                symbol: "checkmark.circle.fill",
                tint: tint,
                onOpenMainWindow: { model.openSelectedSessionInMainWindow() }
            ) {
                model.dismissDoneDetail()
            }

            OrbPopupDivider(tint: tint)
                .padding(.horizontal, 2)

            ScrollView(.vertical, showsIndicators: true) {
                if let detail = model.doneDetailText, !detail.isEmpty {
                    OrbDoneMarkdownText(text: detail)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                }
            }
            .frame(maxHeight: .infinity)

            if showsFollowUpComposer {
                OrbPopupDivider(tint: tint)
                    .padding(.horizontal, 2)

                popupFollowUpComposerSection(
                    tint: tint,
                    placeholder: model.isVoiceRecording ? "Listening..." : "Follow up...",
                    enterHint: "Enter sends",
                    submit: sendDoneFollowUp
                )
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            } else {
                OrbPopupDivider(tint: tint)
                    .padding(.horizontal, 2)

                HStack(spacing: 8) {
                    Text("Close this card to return the orb to its ready state.")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.60))
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 8)

                    OrbSecondaryActionButton(
                        title: "Open Main Window",
                        symbol: "arrow.up.right.square",
                        tint: tint
                    ) {
                        model.openSelectedSessionInMainWindow()
                    }

                    OrbSecondaryActionButton(title: "Ready", symbol: "sparkles", tint: tint) {
                        model.dismissDoneDetail()
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: maxHeight)
        .orbPopupSurface(tint: tint, cornerRadius: 20)
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
    }

    private func modeSwitchPopup(maxHeight: CGFloat) -> some View {
        let tint = Color.orange

        return VStack(spacing: 0) {
            OrbPopupHeader(
                title: "Mode switch",
                subtitle: "Quick way to continue in the right mode",
                symbol: "arrow.triangle.branch",
                tint: tint
            ) {
                model.onDismissModeSwitchSuggestion?()
            }

            OrbPopupDivider(tint: tint)
                .padding(.horizontal, 2)

            ScrollView(.vertical, showsIndicators: false) {
                if let suggestion = model.modeSwitchSuggestion {
                    modeSwitchInlineCard(suggestion, tint: tint)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: maxHeight)
        .orbPopupSurface(tint: tint, cornerRadius: 20)
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func modeSwitchInlineCard(_ suggestion: AssistantModeSwitchSuggestion, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(suggestion.message)
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                ForEach(suggestion.choices) { choice in
                    OrbSecondaryActionButton(
                        title: choice.title,
                        symbol: choice.mode.icon,
                        tint: tint
                    ) {
                        model.interactionMode = choice.mode
                        model.onApplyModeSwitchSuggestion?(choice)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .orbInsetSurface(tint: tint, cornerRadius: 16, fillOpacity: 0.10)
    }

    // MARK: Working Detail Popup

    private func workingDetailPopup(maxHeight: CGFloat) -> some View {
        let tint = glowColor

        return VStack(spacing: 0) {
            OrbPopupHeader(
                title: model.workingPopupTitle.lowercased().capitalized,
                subtitle: "Live progress and quick steering",
                symbol: "waveform.path.ecg",
                tint: tint
            ) {
                model.dismissWorkingDetail()
            }

            OrbPopupDivider(tint: tint)
                .padding(.horizontal, 2)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.state.title)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.94))

                    if let summary = model.workingSummaryText, !summary.isEmpty {
                        Text(summary)
                            .font(.system(size: 11.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.72))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let session = model.activeSessionSummary {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Active session")
                                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                                .tracking(0.6)
                                .textCase(.uppercase)
                                .foregroundStyle(tint.opacity(0.92))

                            Text(session.title.isEmpty ? "Untitled Session" : session.title)
                                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.90))
                            if let cwd = session.cwd?.nonEmpty {
                                Text(cwd)
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.50))
                                    .lineLimit(2)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .orbInsetSurface(tint: tint, cornerRadius: 16, fillOpacity: 0.10)
                    }

                    if !model.workingToolActivity.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Live steps")
                                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.52))

                            ForEach(Array(model.workingToolActivity.prefix(4))) { item in
                                OrbWorkingActivityRow(item: item, tint: tint)
                            }
                        }
                    } else {
                        Text("Detailed step output has not arrived yet, but the agent is still working.")
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.48))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .frame(maxHeight: .infinity)

            OrbPopupDivider(tint: tint)
                .padding(.horizontal, 2)

            VStack(spacing: 10) {
                popupFollowUpComposerSection(
                    tint: tint,
                    placeholder: model.isVoiceRecording
                        ? "Listening..."
                        : "Steer it or prepare the next follow-up...",
                    enterHint: "Enter steers now",
                    submit: sendWorkingFollowUp
                )

                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(tint.opacity(0.85))
                    Text("Typing here interrupts the current turn and applies your new instruction.")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.58))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .orbInsetSurface(tint: tint, cornerRadius: 14, fillOpacity: 0.07)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: maxHeight)
        .orbPopupSurface(tint: tint, cornerRadius: 20)
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
    }

    // MARK: Permission Popup

    private func permissionPopup(maxHeight: CGFloat) -> some View {
        let orangeTint = Color(red: 0.95, green: 0.60, blue: 0.10)

        return VStack(spacing: 0) {
            OrbPopupHeader(
                title: permissionHeaderTitle.lowercased().capitalized,
                subtitle: "Review before the assistant continues",
                symbol: "hand.raised.fill",
                tint: orangeTint
            ) {
                model.onCancelPermission?()
            }

            OrbPopupDivider(tint: orangeTint)
                .padding(.horizontal, 2)

            if let request = model.pendingPermissionRequest {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(request.toolTitle)
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.94))

                        if let rationale = request.rationale, !rationale.isEmpty {
                            Text(rationale)
                                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.70))
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if let summary = request.rawPayloadSummary, !summary.isEmpty {
                            Text(summary)
                                .font(.system(size: 11, weight: .regular, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.58))
                                .lineLimit(4)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .orbInsetSurface(tint: orangeTint, cornerRadius: 14, fillOpacity: 0.08)
                        }

                        VStack(spacing: 8) {
                            ForEach(request.options) { option in
                                OrbPermissionChoiceButton(
                                    title: option.title,
                                    tint: orangeTint,
                                    isProminent: option.isDefault
                                ) {
                                    model.onResolvePermission?(option.id)
                                }
                            }

                            if let toolKind = request.toolKind, !toolKind.isEmpty {
                                OrbPermissionChoiceButton(
                                    title: "Always Allow",
                                    tint: orangeTint,
                                    isProminent: false,
                                    icon: "checkmark.shield.fill"
                                ) {
                                    model.onAlwaysAllowPermission?(toolKind)
                                    let sessionOption = request.options.first(where: { $0.id == "acceptForSession" })
                                        ?? request.options.first(where: { $0.isDefault })
                                    if let optionID = sessionOption?.id {
                                        model.onResolvePermission?(optionID)
                                    }
                                }
                            }
                        }

                        OrbSecondaryActionButton(title: "Cancel Request", symbol: "xmark", tint: Color.white.opacity(0.55)) {
                            model.onCancelPermission?()
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: maxHeight)
        .orbPopupSurface(tint: orangeTint, cornerRadius: 20)
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
    }

    // MARK: Session Popover

    private var sessionPopoverSection: some View {
        VStack(spacing: 0) {
            sessionListSection
        }
        .orbPopupSurface(tint: AppVisualTheme.baseTint, cornerRadius: 18)
    }

    // MARK: Session List

    private var sessionListSection: some View {
        VStack(spacing: 0) {
            // New session button
            Button(action: {
                Task { await model.onNewSession?() }
            }) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(AppVisualTheme.accentTint.opacity(0.18))
                            .frame(width: 24, height: 24)
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(AppVisualTheme.accentTint)
                    }
                    Text("New Session")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                    Spacer()
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.35))
                }
                .foregroundStyle(.white.opacity(0.88))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .orbInsetSurface(tint: AppVisualTheme.accentTint, cornerRadius: 14, fillOpacity: 0.10)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.top, 12)

            if model.showDoneDetail {
                doneDetailPopup(maxHeight: 180, showsFollowUpComposer: false)
                    .padding(.top, 8)
            } else if model.pendingPermissionRequest != nil {
                permissionPopup(maxHeight: 240)
                    .padding(.top, 8)
            } else if model.showWorkingDetail {
                workingDetailPopup(maxHeight: 200)
                    .padding(.top, 8)
            } else if let suggestion = model.modeSwitchSuggestion {
                modeSwitchInlineCard(suggestion, tint: AppVisualTheme.accentTint)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }

            // Session list
            if model.isLoadingSessions {
                ProgressView()
                    .scaleEffect(0.7)
                    .tint(.white.opacity(0.5))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else if model.sessions.isEmpty {
                Text("No sessions yet")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else {
                ScrollView(.vertical, showsIndicators: model.sessions.count > 4) {
                    VStack(spacing: 6) {
                        ForEach(model.sessions.prefix(5)) { session in
                            Button {
                                let clickCount = NSApp.currentEvent?.clickCount ?? 1
                                if clickCount >= 2 {
                                    model.showFollowUpPreview(for: session)
                                } else {
                                    model.selectSessionForReply(session)
                                }
                            } label: {
                                OrbSessionRow(
                                    session: session,
                                    isSelected: session.id == model.selectedSessionID,
                                    isBusy: sessionMatches(session.id, model.busySessionID)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    model.onOpenSession?(session)
                                } label: {
                                    Label("Open Conversation", systemImage: "arrow.up.right.square")
                                }

                                Button {
                                    model.showFollowUpPreview(for: session)
                                } label: {
                                    Label("Show Follow-Up", systemImage: "bubble.left.and.text.bubble.right")
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
                }
                .frame(maxHeight: expandedSessionListMaxHeight)
            }

            // Target indicator
            if let name = model.targetSessionName {
                compactTargetIndicator(name: name)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
            }

            // Message input with inline mode + model picker
            VStack(spacing: 6) {
                if !model.attachments.isEmpty {
                    orbAttachmentStrip(tint: glowColor)
                }

                HStack(alignment: .center, spacing: 6) {
                    orbAttachmentButton(tint: glowColor, size: 24)

                    AssistantModePicker(selection: model.interactionMode, style: .micro) { mode in
                        model.setInteractionMode(mode)
                    }

                    Spacer(minLength: 0)

                    orbModelPicker()
                }

                HStack(alignment: .center, spacing: 6) {
                    orbComposerField(
                        tint: AppVisualTheme.baseTint,
                        placeholder: model.isVoiceRecording ? "Listening..." : "Send a message...",
                        minHeight: 30,
                        maxHeight: 34,
                        cornerRadius: 13,
                        fillOpacity: 0.055,
                        submit: sendMessage
                    )
                    .layoutPriority(1)

                    HStack(spacing: 5) {
                        orbVoiceToggleButton(size: 20)

                        OrbFloatingActionButton(
                            symbol: "arrow.up",
                            tint: glowColor,
                            isEnabled: canSend && !model.isVoiceRecording,
                            size: 20
                        ) {
                            sendMessage()
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(Color.white.opacity(0.035))
                            .overlay(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .stroke(Color.white.opacity(0.05), lineWidth: 0.5)
                            )
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .orbInsetSurface(tint: AppVisualTheme.baseTint, cornerRadius: 13, fillOpacity: 0.042)
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 6)
        }
    }

    // MARK: Helpers

    private func popupFollowUpComposerSection(
        tint: Color,
        placeholder: String,
        enterHint: String,
        submit: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 10) {
            if let suggestion = model.modeSwitchSuggestion {
                modeSwitchInlineCard(suggestion, tint: tint)
            }

            HStack(alignment: .center, spacing: 8) {
                orbAttachmentButton(tint: tint, size: 28)
                AssistantModePicker(selection: model.interactionMode, style: .compact) { mode in
                    model.setInteractionMode(mode)
                }
                orbModelPicker(maxWidth: 138, showsLabel: true, tint: tint)
                Spacer(minLength: 0)
            }

            if !model.attachments.isEmpty {
                orbAttachmentStrip(tint: tint)
            }

            popupComposerCard(
                tint: tint,
                placeholder: placeholder,
                submit: submit
            )
        }
    }

    private func orbModelPicker(
        maxWidth: CGFloat = 74,
        showsLabel: Bool = false,
        tint: Color? = nil
    ) -> some View {
        let effectiveTint = tint ?? AppVisualTheme.accentTint
        return Menu {
            ForEach(model.availableModels) { m in
                Button {
                    model.onChooseModel?(m.id)
                } label: {
                    Text(m.displayName)
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(effectiveTint.opacity(0.9))
                if showsLabel {
                    Text("Model")
                        .font(.system(size: 8.8, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.62))
                }
                Text(model.selectedModelSummary)
                    .font(.system(size: showsLabel ? 9.2 : 8.6, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(showsLabel ? 0.68 : 0.50))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.18))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.04))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(0.05), lineWidth: 0.5)
                    )
            )
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: maxWidth)
        .disabled(model.availableModels.isEmpty)
    }

    private var canSend: Bool {
        !model.messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.attachments.isEmpty
    }

    private var orbDropTypes: [UTType] {
        [.fileURL, .image, .png, .jpeg]
    }

    private func compactTargetIndicator(name: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.turn.right.down")
                .font(.system(size: 7.5, weight: .bold))
            Text("To: \(name)")
                .lineLimit(1)
        }
        .font(.system(size: 8.8, weight: .medium, design: .rounded))
        .foregroundStyle(.white.opacity(0.54))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(AppVisualTheme.accentTint.opacity(0.06))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(0.05), lineWidth: 0.5)
                )
        )
    }

    private func orbVoiceToggleButton(size: CGFloat = 24) -> some View {
        AssistantPushToTalkButton(
            isListening: model.isVoiceRecording,
            level: CGFloat(model.level),
            size: size
        ) { isPressed in
            if isPressed {
                model.onStartVoiceRecording?()
            } else if model.isVoiceRecording {
                model.onStopVoiceRecording?()
            }
        }
    }

    private func handleOrbTap() {
        model.handleOrbTap()
    }

    private func sendDoneFollowUp() {
        let trimmed = model.messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        model.onSendMessage?(trimmed, model.selectedSessionID)
        model.messageText = ""
        model.dismissDoneDetail()
    }

    private func sendWorkingFollowUp() {
        let trimmed = model.messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        model.onSendMessage?(trimmed, model.selectedSessionID)
        model.messageText = ""
        model.dismissWorkingDetail()
    }

    private func sendMessage() {
        let trimmed = model.messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        if model.showDoneDetail {
            model.dismissDoneDetail()
        }
        if model.showWorkingDetail {
            model.dismissWorkingDetail()
        }
        model.onSendMessage?(trimmed, model.selectedSessionID)
        model.collapse()
    }

    @ViewBuilder
    private func orbComposerField(
        tint: Color,
        placeholder: String,
        minHeight: CGFloat,
        maxHeight: CGFloat,
        cornerRadius: CGFloat = 18,
        fillOpacity: Double = 0.11,
        showsSurface: Bool = true,
        submit: @escaping () -> Void
    ) -> some View {
        let textView = OrbComposerTextView(
            text: $model.messageText,
            placeholder: placeholder,
            isEnabled: !model.isVoiceRecording,
            shouldFocus: model.shouldFocusTextField,
            onSubmit: submit,
            onToggleMode: { model.cycleInteractionMode() },
            onPasteAttachment: { attachment in
                addAttachment(attachment)
            }
        )
        .frame(minHeight: minHeight, maxHeight: maxHeight)
        .onDrop(of: orbDropTypes, isTargeted: nil) { providers in
            handleAttachmentDrop(providers)
            return true
        }

        if showsSurface {
            textView
                .orbInsetSurface(tint: tint, cornerRadius: cornerRadius, fillOpacity: fillOpacity)
        } else {
            textView
        }
    }

    private func popupComposerCard(
        tint: Color,
        placeholder: String,
        submit: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 0) {
            orbComposerField(
                tint: tint,
                placeholder: placeholder,
                minHeight: 36,
                maxHeight: 72,
                cornerRadius: 18,
                fillOpacity: 0.0,
                showsSurface: false,
                submit: submit
            )
            .padding(.horizontal, 2)
            .padding(.top, 2)

            OrbPopupDivider(tint: tint)
                .padding(.horizontal, 10)

            HStack(spacing: 8) {
                Text(model.isVoiceRecording ? "Release to stop" : "Enter sends")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.52))
                Spacer(minLength: 0)
                orbVoiceToggleButton(size: 22)
                OrbFloatingActionButton(
                    symbol: "arrow.up",
                    tint: tint,
                    isEnabled: canSend && !model.isVoiceRecording,
                    size: 26
                ) {
                    submit()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .orbInsetSurface(tint: tint, cornerRadius: 20, fillOpacity: 0.08)
    }

    private func orbAttachmentStrip(tint: Color) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.attachments) { attachment in
                    orbAttachmentChip(attachment, tint: tint)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 1)
        }
    }

    private func orbAttachmentChip(_ attachment: AssistantAttachment, tint: Color) -> some View {
        HStack(spacing: 6) {
            if attachment.isImage, let nsImage = NSImage(data: attachment.data) {
                Button {
                    previewAttachment = attachment
                } label: {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 20, height: 20)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: "doc.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint.opacity(0.92))
            }

            Text(attachment.filename)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.70))
                .lineLimit(1)

            Button {
                removeAttachment(attachment)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.42))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.08))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(tint.opacity(0.16), lineWidth: 0.6)
                )
        )
    }

    private func orbAttachmentButton(tint: Color, size: CGFloat = 34) -> some View {
        OrbIconControlButton(symbol: "paperclip", tint: tint, size: size) {
            model.onOpenAttachmentPicker?()
        }
    }

    private func addAttachment(_ attachment: AssistantAttachment) {
        model.onAddAttachment?(attachment)
    }

    private func removeAttachment(_ attachment: AssistantAttachment) {
        model.onRemoveAttachment?(attachment.id)
    }

    private func handleAttachmentDrop(_ providers: [NSItemProvider]) {
        AssistantAttachmentSupport.handleDrop(providers) { attachment in
            addAttachment(attachment)
        }
    }

    private var permissionHeaderTitle: String {
        guard let request = model.pendingPermissionRequest else { return "ACTION NEEDED" }
        let normalizedTitle = request.toolTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedTitle.contains("information") || normalizedTitle.contains("input") || normalizedTitle.contains("question") {
            return "INPUT NEEDED"
        }
        return "APPROVAL NEEDED"
    }

    private var phaseLabel: String {
        switch model.state.phase {
        case .idle: return "Ready"
        case .listening: return "Listening"
        case .success: return "Done"
        case .failed: return "Error"
        case .thinking, .acting, .waitingForPermission, .streaming:
            let title = model.state.title
            if !title.isEmpty { return title }
            switch model.state.phase {
            case .thinking: return "Thinking"
            case .acting: return "Working"
            case .waitingForPermission: return "Needs Approval"
            case .streaming: return "Responding"
            default: return "Working"
            }
        }
    }

    private var glowColor: Color {
        OrbSphere.phaseColor(for: model.state.phase)
    }

    private func sessionMatches(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs = lhs?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
              let rhs = rhs?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return false
        }
        return lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }
}

private struct OrbPopupHeader: View {
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color
    var onOpenMainWindow: (() -> Void)?
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(tint.opacity(0.16))
                        .frame(width: 28, height: 28)
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tint)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                        .tracking(0.8)
                        .textCase(.uppercase)
                        .foregroundStyle(.white.opacity(0.88))

                    Text(subtitle)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
            }

            Spacer()

            if let onOpenMainWindow {
                Button(action: onOpenMainWindow) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.62))
                        .frame(width: 28, height: 28)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(0.06))
                                .overlay(
                                    Circle()
                                        .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                                )
                        )
                }
                .buttonStyle(.plain)
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.62))
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.06))
                            .overlay(
                                Circle()
                                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                            )
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }
}

private struct OrbPopupDivider: View {
    let tint: Color

    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.04),
                        tint.opacity(0.24),
                        Color.white.opacity(0.04)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: 1)
    }
}

private struct OrbInlinePill: View {
    let text: String
    var symbol: String? = nil
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 8, weight: .bold))
            }

            Text(text)
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(.white.opacity(0.62))
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(tint.opacity(0.10))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                )
        )
    }
}

private struct OrbFloatingActionButton: View {
    let symbol: String
    let tint: Color
    let isEnabled: Bool
    var size: CGFloat = 42
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: isEnabled
                                ? [tint.opacity(0.96), tint.opacity(0.58)]
                                : [Color.white.opacity(0.10), Color.white.opacity(0.06)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Circle()
                    .stroke(Color.white.opacity(isEnabled ? 0.18 : 0.08), lineWidth: 0.8)

                Image(systemName: symbol)
                    .font(.system(size: max(10, size * 0.33), weight: .bold))
                    .foregroundStyle(isEnabled ? Color.black.opacity(0.78) : Color.white.opacity(0.32))
            }
            .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

private struct OrbSecondaryActionButton: View {
    let title: String
    var symbol: String? = nil
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 9, weight: .semibold))
                }

                Text(title)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.12))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(tint.opacity(0.18), lineWidth: 0.6)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

private struct OrbIconControlButton: View {
    let symbol: String
    let tint: Color
    var isActive = false
    var size: CGFloat = 34
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: isActive
                                ? [tint.opacity(0.26), tint.opacity(0.12)]
                                : [Color.white.opacity(0.08), Color.white.opacity(0.04)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Circle()
                    .stroke(isActive ? tint.opacity(0.30) : Color.white.opacity(0.08), lineWidth: 0.6)

                Image(systemName: symbol)
                    .font(.system(size: max(10, size * 0.4), weight: .semibold))
                    .foregroundStyle(isActive ? tint : Color.white.opacity(0.52))
            }
            .frame(width: size, height: size)
            .scaleEffect(isActive ? 1.06 : 1.0)
            .animation(
                isActive
                    ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                    : .default,
                value: isActive
            )
        }
        .buttonStyle(.plain)
    }
}

private struct OrbPermissionChoiceButton: View {
    let title: String
    let tint: Color
    let isProminent: Bool
    var icon: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                }

                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))

                Spacer(minLength: 0)
            }
            .foregroundStyle(isProminent ? Color.white : tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: isProminent
                                ? [tint.opacity(0.38), tint.opacity(0.20)]
                                : [tint.opacity(0.12), Color.white.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(isProminent ? tint.opacity(0.42) : Color.white.opacity(0.08), lineWidth: 0.6)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

private struct OrbStatusCapsuleBackground: View {
    let tint: Color
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let tokens = AppVisualTheme.glassTokens(
            style: SettingsStore.shared.appChromeStyle,
            reduceTransparency: reduceTransparency
        )

        Capsule(style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        tokens.surfaceTop.opacity(0.54),
                        tint.opacity(0.14),
                        tokens.surfaceBottom.opacity(0.90)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                if tokens.useMaterial {
                    Capsule(style: .continuous)
                        .fill(AppVisualTheme.adaptiveMaterialFill(reduceTransparency: reduceTransparency))
                        .opacity(0.36)
                }
            }
            .overlay(
                RadialGradient(
                    colors: [
                        tint.opacity(0.18),
                        Color.clear
                    ],
                    center: .topLeading,
                    startRadius: 6,
                    endRadius: 100
                )
                .clipShape(Capsule(style: .continuous))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(tokens.strokeTop.opacity(0.18), lineWidth: 0.55)
            )
    }
}

private struct OrbPopupSurfaceModifier: ViewModifier {
    let tint: Color
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let tokens = AppVisualTheme.glassTokens(
            style: SettingsStore.shared.appChromeStyle,
            reduceTransparency: reduceTransparency
        )
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        return content
            .background {
                ZStack {
                    shape
                        .fill(tokens.surfaceBottom.opacity(reduceTransparency ? 0.96 : 0.80))

                    if tokens.useMaterial {
                        shape
                            .fill(AppVisualTheme.adaptiveMaterialFill(reduceTransparency: reduceTransparency))
                            .opacity(0.74)
                    }

                    shape
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.10),
                                    tint.opacity(0.12),
                                    Color.black.opacity(0.18)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    shape
                        .fill(
                            RadialGradient(
                                colors: [
                                    tint.opacity(0.24),
                                    Color.clear
                                ],
                                center: .topLeading,
                                startRadius: 8,
                                endRadius: 240
                            )
                        )

                    shape
                        .fill(
                            RadialGradient(
                                colors: [
                                    AppVisualTheme.baseTint.opacity(0.18),
                                    Color.clear
                                ],
                                center: .bottomTrailing,
                                startRadius: 12,
                                endRadius: 260
                            )
                        )
                }
            }
            .clipShape(shape)
            .overlay {
                shape
                    .stroke(tokens.strokeTop.opacity(0.34), lineWidth: 0.9)
                    .overlay(
                        shape
                            .stroke(Color.black.opacity(0.24), lineWidth: 0.5)
                            .blur(radius: 0.3)
                    )
            }
    }
}

private struct OrbInsetSurfaceModifier: ViewModifier {
    let tint: Color
    let cornerRadius: CGFloat
    let fillOpacity: Double
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        return content
            .background {
                ZStack {
                    shape
                        .fill(Color.white.opacity(fillOpacity * 0.70))

                    if !reduceTransparency {
                        shape
                            .fill(AppVisualTheme.adaptiveMaterialFill(reduceTransparency: reduceTransparency))
                            .opacity(0.18)
                    }

                    shape
                        .fill(
                            LinearGradient(
                                colors: [
                                    tint.opacity(fillOpacity),
                                    Color.clear,
                                    Color.black.opacity(fillOpacity * 0.40)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            }
            .clipShape(shape)
            .overlay {
                shape
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.6)
                    .overlay(
                        shape
                            .stroke(tint.opacity(0.14), lineWidth: 0.5)
                    )
            }
    }
}

private extension View {
    func orbPopupSurface(tint: Color, cornerRadius: CGFloat = 18) -> some View {
        modifier(OrbPopupSurfaceModifier(tint: tint, cornerRadius: cornerRadius))
    }

    func orbInsetSurface(tint: Color, cornerRadius: CGFloat = 14, fillOpacity: Double = 0.08) -> some View {
        modifier(OrbInsetSurfaceModifier(tint: tint, cornerRadius: cornerRadius, fillOpacity: fillOpacity))
    }
}

// MARK: - Session Row

private struct OrbSessionRow: View {
    let session: AssistantSessionSummary
    let isSelected: Bool
    let isBusy: Bool

    var body: some View {
        HStack(spacing: 10) {
            leadingIndicator

            VStack(alignment: .leading, spacing: 3) {
                Text(session.title.isEmpty ? "Untitled Session" : session.title)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)

                if !session.subtitle.isEmpty {
                    Text(session.subtitle)
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.54))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if isSelected && !isBusy {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.60))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: isSelected
                            ? [AppVisualTheme.rowSelection.opacity(0.82), AppVisualTheme.rowSelection.opacity(0.46)]
                            : [AppVisualTheme.panelTint.opacity(0.42), AppVisualTheme.panelTint.opacity(0.28)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(
                            isSelected
                                ? AppVisualTheme.accentTint.opacity(0.30)
                                : Color.white.opacity(0.07),
                            lineWidth: 0.6
                        )
                )
        }
    }

    @ViewBuilder
    private var leadingIndicator: some View {
        if isBusy {
            BusySessionIndicator(tint: AppVisualTheme.accentTint)
                .frame(width: 10, height: 10)
        } else {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
        }
    }

    private var statusColor: Color {
        switch session.status {
        case .active: return .green.opacity(0.85)
        case .waitingForApproval, .waitingForInput: return .orange.opacity(0.85)
        case .completed: return Color(white: 0.50)
        case .failed: return .red.opacity(0.85)
        case .idle, .unknown: return Color(white: 0.35)
        }
    }
}

private struct BusySessionIndicator: View {
    let tint: Color

    var body: some View {
        ProgressView()
            .controlSize(.small)
            .scaleEffect(0.65)
            .tint(tint)
    }
}

private struct OrbWorkingActivityRow: View {
    let item: AssistantToolCallState
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(statusTint.opacity(0.18))
                    .frame(width: 20, height: 20)
                Circle()
                    .fill(statusTint)
                    .frame(width: 7, height: 7)
            }
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.90))

                if let detail = (item.hudDetail ?? item.detail)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
                    Text(detail)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.62))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .orbInsetSurface(tint: tint, cornerRadius: 14, fillOpacity: 0.08)
    }

    private var statusTint: Color {
        let normalized = item.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.contains("fail") || normalized.contains("error") {
            return .red
        }
        if normalized.contains("complete") || normalized.contains("done") {
            return .green
        }
        return .orange
    }
}

private struct OrbComposerTextView: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var isEnabled: Bool = true
    var shouldFocus: Bool = false
    var onSubmit: () -> Void
    var onToggleMode: (() -> Void)? = nil
    var onPasteAttachment: ((AssistantAttachment) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = OrbComposerScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = OrbSubmittableTextView()
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 12.5, weight: .regular)
        textView.textColor = NSColor.white.withAlphaComponent(0.92)
        textView.insertionPointColor = NSColor.white.withAlphaComponent(0.90)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: 12, height: 7)
        textView.textContainer?.lineFragmentPadding = 2
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = context.coordinator
        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled
        textView.onSubmit = onSubmit
        textView.onToggleMode = onToggleMode
        textView.onPasteAttachment = onPasteAttachment
        textView.placeholder = placeholder
        AssistantComposerBridge.shared.register(textView: textView, target: .assistantOrb)

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? OrbSubmittableTextView else { return }
        AssistantComposerBridge.shared.register(textView: textView, target: .assistantOrb)
        if textView.string != text {
            let selectedRanges = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selectedRanges
        }
        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled
        textView.onSubmit = onSubmit
        textView.onToggleMode = onToggleMode
        textView.onPasteAttachment = onPasteAttachment
        textView.placeholder = placeholder
        textView.needsDisplay = true

        if shouldFocus {
            if !context.coordinator.didHandleFocusRequest {
                context.coordinator.didHandleFocusRequest = true
                DispatchQueue.main.async {
                    textView.window?.makeFirstResponder(textView)
                }
            }
        } else {
            context.coordinator.didHandleFocusRequest = false
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: OrbComposerTextView
        var didHandleFocusRequest = false

        init(parent: OrbComposerTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            textView.needsDisplay = true
        }
    }
}

private final class OrbComposerScrollView: NSScrollView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        guard let textView = documentView as? NSTextView, textView.isEditable else {
            super.mouseDown(with: event)
            return
        }

        window?.makeFirstResponder(textView)
        let insertionPoint = textView.string.utf16.count
        textView.setSelectedRange(NSRange(location: insertionPoint, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        textView.needsDisplay = true
    }
}

private final class OrbSubmittableTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onToggleMode: (() -> Void)?
    var onPasteAttachment: ((AssistantAttachment) -> Void)?
    var placeholder: String = ""

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard string.isEmpty, !placeholder.isEmpty else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 12.5, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.38)
        ]
        let placeholderRect = NSRect(
            x: textContainerInset.width + 1,
            y: textContainerInset.height + 1,
            width: bounds.width - (textContainerInset.width * 2) - 4,
            height: bounds.height - (textContainerInset.height * 2)
        )
        NSString(string: placeholder).draw(in: placeholderRect, withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        if isEditable {
            window?.makeFirstResponder(self)
        }
        super.mouseDown(with: event)
        needsDisplay = true
    }

    override func paste(_ sender: Any?) {
        if let attachment = AssistantAttachmentSupport.attachment(fromPasteboard: NSPasteboard.general) {
            onPasteAttachment?(attachment)
            return
        }
        super.paste(sender)
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36
        let isShift = event.modifierFlags.contains(.shift)
        let isTab = event.keyCode == 48

        if isReturn && !isShift {
            onSubmit?()
            return
        }
        if isTab && isShift {
            onToggleMode?()
            return
        }

        super.keyDown(with: event)
        needsDisplay = true
    }
}

// MARK: - Orb Sphere (Siri-inspired)

private struct OrbSphere: View {
    let phase: AssistantHUDPhase
    let level: CGFloat
    let time: TimeInterval

    private let sphereSize: CGFloat = 48
    private let containerSize: CGFloat = 64

    var body: some View {
        let pulse = pulseScale
        let c = colors
        let speed = animSpeed
        let motion = motionAmplitude
        let highlightTravel = highlightTravelDistance

        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            c.primary.opacity(0.44),
                            c.secondary.opacity(0.18),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 6,
                        endRadius: 28
                    )
                )
                .frame(width: containerSize, height: containerSize)
                .blur(radius: 10)
                .scaleEffect((1.02 + ((pulse - 1.0) * 0.65)) * glowBreathingScale)

            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.black.opacity(0.36),
                                c.secondary.opacity(0.58),
                                c.primary.opacity(0.82)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.white.opacity(0.20), c.primary.opacity(0.72), Color.clear],
                            center: UnitPoint(
                                x: 0.42 + (sin(time * speed * 0.26) * highlightTravel * 1.4),
                                y: 0.34 + (cos(time * speed * 0.20) * highlightTravel * 1.1)
                            ),
                            startRadius: 0,
                            endRadius: 24
                        )
                    )
                    .frame(width: 44, height: 44)
                    .offset(
                        x: CGFloat(sin(time * speed * 0.33)) * motion * 0.88,
                        y: CGFloat(cos(time * speed * 0.24)) * motion * 0.62
                    )
                    .blur(radius: 7.0)

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [c.secondary.opacity(0.94), c.accent.opacity(0.22), Color.clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 22
                        )
                    )
                    .frame(width: 36, height: 36)
                    .offset(
                        x: CGFloat(cos(time * speed * 0.50)) * motion * 0.78,
                        y: CGFloat(sin(time * speed * 0.38)) * motion * 0.54
                    )
                    .blur(radius: 6.0)

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.white.opacity(0.26), c.accent.opacity(0.22), Color.clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 16
                        )
                    )
                    .frame(width: 28, height: 28)
                    .offset(
                        x: CGFloat(sin(time * speed * 0.62)) * motion * 0.58,
                        y: CGFloat(cos(time * speed * 0.46)) * motion * 0.64
                    )
                    .blur(radius: 4.8)

                Ellipse()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.black.opacity(0.26),
                                Color.clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 30, height: 16)
                    .offset(y: 14)
                    .blur(radius: 6)

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.white.opacity(0.26),
                                Color.white.opacity(0.08),
                                Color.clear
                            ],
                            center: UnitPoint(
                                x: 0.34 + sin(time * speed * 0.18) * highlightTravel,
                                y: 0.28 + cos(time * speed * 0.14) * highlightTravel
                            ),
                            startRadius: 0,
                            endRadius: 24
                        )
                    )
                    .frame(width: sphereSize, height: sphereSize)
            }
            .frame(width: sphereSize, height: sphereSize)
            .clipShape(Circle())

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(0.32),
                            Color.white.opacity(0.08),
                            Color.clear
                        ],
                        center: UnitPoint(x: 0.36, y: 0.28),
                        startRadius: 0,
                        endRadius: 20
                    )
                )
                .frame(width: sphereSize, height: sphereSize)
                .blendMode(.screen)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(0.82),
                            Color.white.opacity(0.18),
                            Color.clear
                        ],
                        center: UnitPoint(x: 0.30, y: 0.22),
                        startRadius: 0,
                        endRadius: 10
                    )
                )
                .frame(width: sphereSize, height: sphereSize)
                .offset(x: -1, y: -1)

            Circle()
                .strokeBorder(
                    AngularGradient(
                        colors: [
                            c.primary.opacity(0.42),
                            Color.white.opacity(0.28),
                            c.secondary.opacity(0.30),
                            Color.white.opacity(0.14),
                            c.primary.opacity(0.42)
                        ],
                        center: .center
                    ),
                    lineWidth: 1.0
                )
                .frame(width: sphereSize, height: sphereSize)
                .rotationEffect(rimRotation)

            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.18),
                            Color.clear,
                            Color.black.opacity(0.20)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
                .frame(width: sphereSize, height: sphereSize)
        }
        .frame(width: containerSize, height: containerSize)
        .offset(y: floatOffset)
        .scaleEffect(pulse)
    }

    // MARK: Animation

    private var floatOffset: CGFloat {
        switch phase {
        case .thinking: return CGFloat(sin(time * 2.4)) * 1.2
        case .acting: return CGFloat(sin(time * 2.8)) * 1.0
        case .streaming: return CGFloat(sin(time * 2.6)) * 1.1
        case .listening: return CGFloat(sin(time * 2.0)) * 0.8
        default: return 0
        }
    }

    private var pulseScale: CGFloat {
        switch phase {
        case .idle:
            return 1.0
        case .listening:
            return 1.0 + min(level * 0.055, 0.055) + CGFloat(sin(time * 1.6)) * 0.008
        case .thinking:
            return 1.0 + CGFloat(sin(time * 2.5)) * 0.018
        case .acting:
            return 1.002 + CGFloat(sin(time * 3.0)) * 0.020
        case .waitingForPermission:
            return 1.0 + CGFloat(sin(time * 0.8)) * 0.006
        case .streaming:
            return 1.002 + CGFloat(sin(time * 2.7)) * 0.016
        case .success:
            return 1.008 + CGFloat(sin(time * 0.7)) * 0.003
        case .failed:
            return 1.0 + CGFloat(sin(time * 2.2)) * 0.010
        }
    }

    /// Controls how fast the internal blobs drift.
    private var animSpeed: Double {
        switch phase {
        case .idle: return 0.0
        case .listening: return 1.35 + Double(min(level, 1)) * 0.55
        case .thinking: return 1.05
        case .acting: return 1.45
        case .waitingForPermission: return 0.55
        case .streaming: return 1.20
        case .success: return 0.80
        case .failed: return 1.65
        }
    }

    private var motionAmplitude: CGFloat {
        switch phase {
        case .idle:
            return 0.0
        case .listening:
            return 3.2 + min(level * 1.4, 1.4)
        case .thinking:
            return 2.9
        case .acting:
            return 3.4
        case .waitingForPermission:
            return 2.1
        case .streaming:
            return 3.0
        case .success:
            return 2.0
        case .failed:
            return 2.8
        }
    }

    private var highlightTravelDistance: CGFloat {
        switch phase {
        case .idle:
            return 0.0
        case .success:
            return 0.04
        case .listening, .acting, .streaming:
            return 0.06
        case .thinking, .waitingForPermission, .failed:
            return 0.05
        }
    }

    private var glowBreathingScale: CGFloat {
        switch phase {
        case .thinking: return 1.0 + CGFloat(sin(time * 2.8)) * 0.05
        case .acting: return 1.0 + CGFloat(sin(time * 3.2)) * 0.05
        case .streaming: return 1.0 + CGFloat(sin(time * 3.0)) * 0.04
        default: return 1.0
        }
    }

    private var rimRotation: Angle {
        switch phase {
        case .thinking: return .degrees(time * 30)
        case .acting: return .degrees(time * 40)
        case .streaming: return .degrees(time * 35)
        default: return .zero
        }
    }

    // MARK: Colors

    private struct OrbColors {
        let primary: Color
        let secondary: Color
        let accent: Color
    }

    private var colors: OrbColors {
        switch phase {
        case .idle:
            return OrbColors(
                primary: AppVisualTheme.accentTint,
                secondary: AppVisualTheme.accentTint.opacity(0.65),
                accent: Color.white.opacity(0.30)
            )
        case .listening:
            return OrbColors(
                primary: Color(red: 0.0, green: 0.75, blue: 0.95),
                secondary: Color(red: 0.20, green: 0.30, blue: 0.90),
                accent: Color(red: 0.10, green: 0.85, blue: 0.80)
            )
        case .thinking:
            return OrbColors(
                primary: Color(red: 0.50, green: 0.30, blue: 0.95),
                secondary: Color(red: 0.75, green: 0.35, blue: 0.90),
                accent: Color(red: 0.35, green: 0.20, blue: 0.80)
            )
        case .acting:
            return OrbColors(
                primary: Color(red: 0.10, green: 0.82, blue: 0.72),
                secondary: Color(red: 0.25, green: 0.90, blue: 0.55),
                accent: Color(red: 0.06, green: 0.52, blue: 0.48)
            )
        case .waitingForPermission:
            return OrbColors(
                primary: Color(red: 0.95, green: 0.60, blue: 0.10),
                secondary: Color(red: 0.95, green: 0.80, blue: 0.20),
                accent: Color(red: 0.72, green: 0.38, blue: 0.05)
            )
        case .streaming:
            return OrbColors(
                primary: Color(red: 0.28, green: 0.65, blue: 0.98),
                secondary: Color(red: 0.45, green: 0.80, blue: 0.98),
                accent: Color(red: 0.18, green: 0.42, blue: 0.85)
            )
        case .success:
            return OrbColors(
                primary: Color(red: 0.20, green: 0.85, blue: 0.45),
                secondary: Color(red: 0.45, green: 0.92, blue: 0.55),
                accent: Color(red: 0.15, green: 0.60, blue: 0.35)
            )
        case .failed:
            return OrbColors(
                primary: Color(red: 0.92, green: 0.20, blue: 0.20),
                secondary: Color(red: 0.95, green: 0.35, blue: 0.15),
                accent: Color(red: 0.65, green: 0.10, blue: 0.12)
            )
        }
    }

    static func phaseColor(for phase: AssistantHUDPhase) -> Color {
        switch phase {
        case .idle: return AppVisualTheme.accentTint
        case .listening: return Color(red: 0.0, green: 0.75, blue: 0.95)
        case .thinking: return Color(red: 0.45, green: 0.25, blue: 0.90)
        case .acting: return Color(red: 0.10, green: 0.82, blue: 0.72)
        case .waitingForPermission: return .orange
        case .streaming: return Color(red: 0.22, green: 0.60, blue: 0.95)
        case .success: return Color(red: 0.15, green: 0.80, blue: 0.40)
        case .failed: return .red
        }
    }
}

// MARK: - Done Detail Markdown

private struct OrbDoneMarkdownText: View {
    let text: String

    var body: some View {
        Markdown(text)
            .markdownTheme(orbDoneTheme)
            .markdownCodeSyntaxHighlighter(.plainText)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var orbDoneTheme: MarkdownUI.Theme {
        .init()
            .text {
                ForegroundColor(.white.opacity(0.88))
                FontSize(13)
            }
            .heading1 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontSize(16)
                        FontWeight(.bold)
                        ForegroundColor(.white.opacity(0.92))
                    }
                    .markdownMargin(top: 10, bottom: 6)
            }
            .heading2 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontSize(14.5)
                        FontWeight(.bold)
                        ForegroundColor(.white.opacity(0.90))
                    }
                    .markdownMargin(top: 8, bottom: 5)
            }
            .heading3 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontSize(13.5)
                        FontWeight(.semibold)
                        ForegroundColor(.white.opacity(0.88))
                    }
                    .markdownMargin(top: 6, bottom: 4)
            }
            .strong {
                FontWeight(.semibold)
                ForegroundColor(.white.opacity(0.92))
            }
            .emphasis {
                FontStyle(.italic)
            }
            .link {
                ForegroundColor(AppVisualTheme.accentTint)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(12)
                ForegroundColor(.white.opacity(0.82))
                BackgroundColor(Color(red: 0.10, green: 0.10, blue: 0.13))
            }
            .codeBlock { configuration in
                ScrollView(.horizontal, showsIndicators: true) {
                    configuration.label
                        .markdownTextStyle {
                            FontFamilyVariant(.monospaced)
                            FontSize(12)
                            ForegroundColor(.white.opacity(0.82))
                        }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(red: 0.06, green: 0.06, blue: 0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color.white.opacity(0.07), lineWidth: 0.5)
                        )
                )
                .markdownMargin(top: 4, bottom: 4)
            }
            .blockquote { configuration in
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(AppVisualTheme.accentTint.opacity(0.4))
                        .frame(width: 2.5)
                    configuration.label
                        .markdownTextStyle {
                            ForegroundColor(.white.opacity(0.7))
                            FontStyle(.italic)
                        }
                        .padding(.leading, 8)
                }
                .markdownMargin(top: 3, bottom: 3)
            }
            .listItem { configuration in
                configuration.label
                    .markdownMargin(top: 2, bottom: 2)
            }
            .paragraph { configuration in
                configuration.label
                    .markdownMargin(top: 3, bottom: 3)
            }
    }
}
