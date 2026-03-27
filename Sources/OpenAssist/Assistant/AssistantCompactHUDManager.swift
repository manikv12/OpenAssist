import AppKit
import Combine
import SwiftUI

// MARK: - Manager

private let kOrbPositionKey = "assistantOrbHUDPosition"

enum AssistantNotchLayout {
    static func revealZone(
        for hiddenFrame: NSRect,
        horizontalPadding: CGFloat,
        minimumHoverHeight: CGFloat,
        verticalPadding: CGFloat
    ) -> NSRect {
        let expandedHeight = max(minimumHoverHeight, hiddenFrame.height + (verticalPadding * 2))
        return NSRect(
            x: hiddenFrame.minX - horizontalPadding,
            y: hiddenFrame.minY - verticalPadding,
            width: hiddenFrame.width + (horizontalPadding * 2),
            height: expandedHeight
        )
    }

    static func verticalOffset(
        topBandHeight: CGFloat,
        safeAreaTop: CGFloat,
        visibleTopInset: CGFloat,
        hiddenHeight: CGFloat,
        requestedHeight: CGFloat,
        spacingBelowNotch: CGFloat
    ) -> CGFloat {
        // Only content intentionally docked inside the notch (≤ hiddenHeight) stays behind it.
        // All taller content — collapsed pill, compact card, expanded tray — must sit below.
        guard requestedHeight > (hiddenHeight + 0.5) else { return 0 }

        return contentTopInset(
            topBandHeight: topBandHeight,
            safeAreaTop: safeAreaTop,
            visibleTopInset: visibleTopInset,
            spacingBelowNotch: spacingBelowNotch
        )
    }

    static func centeredOriginX(screenFrame: NSRect, width: CGFloat) -> CGFloat {
        let centeredX = screenFrame.midX - (width / 2)
        return round(max(screenFrame.minX, min(centeredX, screenFrame.maxX - width)))
    }

    static func contentTopInset(
        topBandHeight: CGFloat,
        safeAreaTop: CGFloat,
        visibleTopInset: CGFloat,
        spacingBelowNotch: CGFloat
    ) -> CGFloat {
        let unobscuredTopInset = max(topBandHeight, safeAreaTop, visibleTopInset)
        guard unobscuredTopInset > 0 else { return 0 }
        return unobscuredTopInset + spacingBelowNotch
    }
}

enum AssistantNotchInteraction {
    struct HoverState: Equatable {
        var start: Date?
        var displayID: CGDirectDisplayID?
    }

    static func updatedHoverState(
        current: HoverState,
        hoveredDisplayID: CGDirectDisplayID?,
        isEligible: Bool,
        now: Date
    ) -> HoverState {
        guard isEligible, let hoveredDisplayID else {
            return HoverState(start: nil, displayID: nil)
        }

        if current.displayID == hoveredDisplayID, current.start != nil {
            return current
        }

        return HoverState(start: now, displayID: hoveredDisplayID)
    }

    static func shouldReveal(
        hoverStart: Date?,
        now: Date,
        revealDelay: TimeInterval
    ) -> Bool {
        guard let hoverStart else { return false }
        return now.timeIntervalSince(hoverStart) >= revealDelay
    }

    static func shouldAllowMousePassthrough(
        isDockRevealed: Bool,
        shouldDockCollapsed: Bool,
        isShowingCompactCard: Bool,
        isExpanded: Bool
    ) -> Bool {
        !isDockRevealed && shouldDockCollapsed && !isShowingCompactCard && !isExpanded
    }
}

@MainActor
final class AssistantCompactHUDManager: AssistantCompactPresenter {
    private enum NotchAnchorMode {
        case hardwareNotch(NSRect)
        case syntheticNotch
    }

    private enum Layout {
        static let orbCollapsedSize = NSSize(width: 140, height: 156)
        static let orbExpandedSize = AssistantOrbHUDModel.Layout.expandedSize
        static let notchCollapsedSize = NSSize(width: 320, height: 50)
        static let notchCompactCardSize = NSSize(width: 520, height: 480)
        static let notchExpandedSize = NSSize(width: 1100, height: 462)
        static let notchScreenFollowInterval: TimeInterval = 0.06
        static let notchDockHiddenVisibleHeight: CGFloat = 4
        static let notchDockHoverBandHeight: CGFloat = 18
        static let notchDockHoverPadding: CGFloat = 18
        static let notchDockHideDelay: TimeInterval = 0.9
        static let notchBelowCameraSpacing: CGFloat = 8
        static let notchActiveGlowExtension: CGFloat = 10
    }

    private let model = AssistantOrbHUDModel()
    private let controller: AssistantStore
    private let settings: SettingsStore
    private var panel: OrbHUDPanel?
    private var cancellables = Set<AnyCancellable>()
    private var clickOutsideMonitor: Any?
    private var notchScreenFollowTimer: Timer?
    private var lastLiveVoiceSessionPhase: AssistantLiveVoiceSessionPhase = .idle
    private var isNotchDockRevealed = false
    private var notchDockHideDeadline: Date?
    private var notchDockRevealHoverState = AssistantNotchInteraction.HoverState()
    private var lastAppliedNotchDockReveal = false
    private var suppressNotchDockRevealUntilPointerLeaves = false

    /// Saved orb origin (bottom-left of collapsed frame). `nil` = use default center position.
    private var savedOrigin: NSPoint?
    private var preferredDisplayID: CGDirectDisplayID?
    private var presentationStyle: AssistantCompactPresentationStyle

    var currentScreen: NSScreen? {
        if let panelScreen = panel?.screen {
            return panelScreen
        }
        return screenForPreferredDisplay()
    }

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

    init(
        controller: AssistantStore,
        settings: SettingsStore,
        style: AssistantCompactPresentationStyle = .orb
    ) {
        self.controller = controller
        self.settings = settings
        self.presentationStyle = style

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

        controller.$timelineItems
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
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

        model.$showCompactComposer
            .sink { [weak self] showing in
                self?.handleCompactComposerChange(showing)
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

        model.onOpenMainWindow = {
            NotificationCenter.default.post(name: .openAssistOpenAssistant, object: nil)
        }

        model.onNewSession = { [weak self] in
            await self?.controller.startNewSession()
            await self?.refreshSessionsForOrb()
        }

        model.onNewTemporarySession = { [weak self] in
            await self?.controller.startNewTemporarySession()
            await self?.refreshSessionsForOrb()
        }

        model.onPromoteTemporarySession = { [weak self] sessionID in
            guard let self else { return }
            self.controller.promoteTemporarySession(sessionID)
            self.syncModelFromController()
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

        model.onStartLiveVoiceSession = { [weak self] in
            self?.controller.startLiveVoiceSession(surface: .compactHUD)
            self?.syncModelFromController()
        }

        model.onEndLiveVoiceSession = { [weak self] in
            self?.controller.endLiveVoiceSession()
            self?.syncModelFromController()
        }

        model.onStopLiveVoiceSpeaking = { [weak self] in
            self?.controller.stopSpeakingAndResumeListening()
            self?.syncModelFromController()
        }

        model.onStopActiveTurn = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.controller.cancelActiveTurn()
                self.syncModelFromController()
            }
        }

        model.onHideDock = { [weak self] in
            guard let self, self.presentationStyle == .notch else { return }
            self.isNotchDockRevealed = false
            self.notchDockHideDeadline = nil
            self.suppressNotchDockRevealUntilPointerLeaves = true
            self.syncNotchDockPresentation()
            self.reposition()
            self.updateNotchScreenFollowTimer()
        }

        model.onResolvePermission = { [weak self] optionID in
            guard let self else { return }
            Task { await self.controller.resolvePermission(optionID: optionID) }
        }

        model.onSubmitPermissionAnswers = { [weak self] answers in
            guard let self else { return }
            Task { await self.controller.resolvePermission(answers: answers) }
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

        controller.$liveVoiceSessionSnapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in
                guard let self else { return }
                let previousPhase = self.lastLiveVoiceSessionPhase
                self.lastLiveVoiceSessionPhase = snapshot.phase
                self.handleNotchLiveVoiceTurnHandoff(from: previousPhase, to: snapshot)
                self.model.liveVoiceSnapshot = snapshot
                self.model.isVoiceRecording = snapshot.isListening
                self.syncModelFromController()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.handleDisplayEnvironmentChange()
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.handleDisplayEnvironmentChange()
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.screensDidWakeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.handleDisplayEnvironmentChange()
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.handleDisplayEnvironmentChange()
            }
            .store(in: &cancellables)

        syncModelFromController()

        // Show the compact assistant immediately only when the current style
        // should stay visible while idle.
        if isEnabled, shouldPresent(.idle) {
            show(state: .idle)
        }
    }

    // MARK: Public

    func setPresentationStyle(_ style: AssistantCompactPresentationStyle) {
        guard presentationStyle != style else { return }
        preferredDisplayID = currentScreen.flatMap(Self.displayID(for:))
        presentationStyle = style
        rebuildPanelForCurrentStyle()
    }

    func setPreferredScreen(_ screen: NSScreen?) {
        preferredDisplayID = screen.flatMap(Self.displayID(for:))
        if panel?.isVisible == true {
            reposition()
            updateNotchScreenFollowTimer()
        }
    }

    func prepareVoiceCaptureComposer() {
        guard isEnabled else { return }
        if panel == nil { createPanel() }
        NSApp.activate(ignoringOtherApps: true)
        _ = model.presentCompactComposerIfAvailable()
        panel?.orderFrontRegardless()
    }

    func show(state: AssistantHUDState) {
        guard isEnabled else { return }
        if panel == nil { createPanel() }
        guard let panel else { return }
        if presentationStyle == .notch {
            if panel.isVisible {
                preserveCurrentNotchScreenAsPreferredDisplay()
            } else {
                captureMouseScreenAsPreferredDisplay()
            }
        }
        model.update(state: effectiveDisplayState(for: state))
        if presentationStyle == .notch || !panel.isVisible || panel.frame.size != targetSize {
            reposition()
        }
        panel.orderFrontRegardless()
        updateNotchScreenFollowTimer()
    }

    func update(state: AssistantHUDState) {
        autoDismissItem?.cancel()
        autoDismissItem = nil

        guard isEnabled, shouldPresent(state) else {
            hide()
            return
        }

        show(state: effectiveDisplayState(for: state))
        scheduleAutoDismissIfNeeded(for: state)
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
        autoDismissItem?.cancel()
        autoDismissItem = nil
        model.collapse()
        model.update(state: .idle)
        model.updateLevel(0)
        isNotchDockRevealed = false
        notchDockHideDeadline = nil
        notchDockRevealHoverState = AssistantNotchInteraction.HoverState()
        suppressNotchDockRevealUntilPointerLeaves = false
        stopClickOutsideMonitor()
        stopNotchScreenFollowTimer()
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
        if presentationStyle == .notch {
            return true
        }

        return true
    }

    private func createPanel() {
        let panel = OrbHUDPanel(
            contentRect: NSRect(origin: .zero, size: targetSize),
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
        panel.allowsOrbDrag = presentationStyle == .orb
        panel.onPositionPersist = { [weak self] in
            guard let self, let panel = self.panel else { return }
            self.persistCollapsedOrigin(
                from: panel.frame.origin,
                panelSize: panel.frame.size
            )
        }
        let hostingController = NSHostingController(
            rootView: AssistantCompactHUDView(style: presentationStyle, model: model)
        )
        // The HUD manager drives panel sizing manually for orb/notch states.
        // Disable SwiftUI's automatic window resizing to avoid AppKit layout loops.
        hostingController.sizingOptions = []
        panel.contentViewController = hostingController
        self.panel = panel
    }

    private var targetSize: NSSize {
        switch presentationStyle {
        case .orb:
            if model.isExpanded { return Layout.orbExpandedSize }
            if model.showDoneDetail
                || model.showWorkingDetail
                || model.pendingPermissionRequest != nil
                || model.modeSwitchSuggestion != nil {
                return model.popupSize
            }
            return Layout.orbCollapsedSize
        case .notch:
            if model.isExpanded {
                return Layout.notchExpandedSize
            }
            if model.pendingPermissionRequest != nil
                || model.showDoneDetail
                || model.showWorkingDetail
                || model.showCompactComposer
                || model.modeSwitchSuggestion != nil {
                return Layout.notchCompactCardSize
            }
            let hiddenWidth = model.notchUsesHardwareOutline
                ? max(1, model.notchDockVisibleWidth)
                : max(120, model.notchDockVisibleWidth)
            let activeGlowExt: CGFloat = model.notchDockRevealed ? 0 : {
                switch model.state.phase {
                case .idle, .success, .failed: return 0
                default: return Layout.notchActiveGlowExtension
                }
            }()
            return NSSize(
                width: model.notchDockRevealed ? Layout.notchCollapsedSize.width : hiddenWidth,
                height: model.notchDockRevealed ? Layout.notchCollapsedSize.height : max(2, model.notchDockVisibleHeight) + activeGlowExt
            )
        }
    }

    private func rebuildPanelForCurrentStyle() {
        let wasVisible = panel?.isVisible == true
        panel?.orderOut(nil)
        panel = nil
        stopClickOutsideMonitor()
        stopNotchScreenFollowTimer()
        isNotchDockRevealed = false
        notchDockHideDeadline = nil
        if wasVisible && isEnabled {
            show(state: model.state)
        }
    }

    private func reposition() {
        guard let panel else { return }
        let screen = screenForCurrentPlacement(panel: panel)
        guard let screen else { return }

        let currentDisplayID = panel.screen.flatMap(Self.displayID(for:))
        let targetDisplayID = Self.displayID(for: screen)
        preferredDisplayID = targetDisplayID
        panel.allowsOrbDrag = presentationStyle == .orb
        syncNotchDockPresentation(for: screen)

        let frame: NSRect
        let persistedPanelSize: NSSize
        switch presentationStyle {
        case .orb:
            let availableFrame = screen.visibleFrame
            let requestedSize = targetSize
            let size = NSSize(
                width: min(requestedSize.width, availableFrame.width),
                height: min(requestedSize.height, availableFrame.height)
            )

            panel.isOrbAnchoredAtBottom = isOrbAnchoredAtBottom

            let origin: NSPoint
            if let saved = savedOrigin {
                if requestedSize != Layout.orbCollapsedSize {
                    let orbCenterX = saved.x + Layout.orbCollapsedSize.width / 2
                    origin = NSPoint(
                        x: orbCenterX - size.width / 2,
                        y: isOrbAnchoredAtBottom
                            ? saved.y
                            : saved.y + Layout.orbCollapsedSize.height - size.height
                    )
                } else {
                    origin = saved
                }
            } else {
                let x = availableFrame.midX - (size.width / 2)
                let y = availableFrame.minY + 36
                origin = NSPoint(x: x, y: y)
            }

            let clampedX = max(availableFrame.minX, min(origin.x, availableFrame.maxX - size.width))
            let clampedY = max(availableFrame.minY, min(origin.y, availableFrame.maxY - size.height))
            frame = NSRect(origin: NSPoint(x: clampedX, y: clampedY), size: size)
            persistedPanelSize = size
        case .notch:
            panel.isOrbAnchoredAtBottom = false
            frame = notchFrame(for: screen)
            persistedPanelSize = frame.size
        }

        let dockRevealChanged = lastAppliedNotchDockReveal != isNotchDockRevealed
        let sizeChanged = panel.frame.size != frame.size
        let shouldAnimateNotch = presentationStyle == .notch
            && currentDisplayID == targetDisplayID
            && (dockRevealChanged || sizeChanged)
            && !model.isExpanded

        CATransaction.begin()
        CATransaction.setDisableActions(!shouldAnimateNotch)
        if shouldAnimateNotch {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true, animate: false)
        }
        CATransaction.commit()
        lastAppliedNotchDockReveal = isNotchDockRevealed

        if presentationStyle == .orb && savedOrigin == nil {
            persistCollapsedOrigin(from: frame.origin, panelSize: persistedPanelSize)
        }
    }

    private func handleDoneDetailChange(_ showing: Bool) {
        guard isEnabled else { return }
        if presentationStyle == .notch {
            if showing {
                if panel == nil { createPanel() }
                preserveCurrentNotchScreenAsPreferredDisplay()
                isNotchDockRevealed = true
                syncNotchDockPresentation()
                panel?.orderFrontRegardless()
                reposition()
            }
            if !showing {
                if model.state.phase == .success || model.state.phase == .failed {
                    resetToIdle()
                }
                // Animate back to collapsed pill first, then let auto-hide
                // handle the dock-into-notch transition after a delay.
                reposition()
                notchDockHideDeadline = Date().addingTimeInterval(Layout.notchDockHideDelay)
            }
            syncNotchCompactTextEntry()
            updateNotchScreenFollowTimer()
            return
        }

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
        guard isEnabled else { return }
        if presentationStyle == .notch {
            if panel == nil { createPanel() }
            if showing {
                preserveCurrentNotchScreenAsPreferredDisplay()
                isNotchDockRevealed = true
                syncNotchDockPresentation()
                panel?.orderFrontRegardless()
            }
            reposition()
            syncNotchCompactTextEntry()
            updateNotchScreenFollowTimer()
            return
        }
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

    private func handleCompactComposerChange(_ showing: Bool) {
        guard isEnabled else { return }
        if presentationStyle == .notch {
            if panel == nil { createPanel() }
            if showing {
                preserveCurrentNotchScreenAsPreferredDisplay()
                isNotchDockRevealed = true
                syncNotchDockPresentation()
                panel?.orderFrontRegardless()
            }
            reposition()
            syncNotchCompactTextEntry()
            updateNotchScreenFollowTimer()
            return
        }

        guard !model.isExpanded else { return }
        reposition()
    }

    private func handleNotchLiveVoiceTurnHandoff(
        from previousPhase: AssistantLiveVoiceSessionPhase,
        to snapshot: AssistantLiveVoiceSessionSnapshot
    ) {
        guard isEnabled, presentationStyle == .notch else { return }
        guard snapshot.surface == .compactHUD, snapshot.isActive else { return }

        switch (previousPhase, snapshot.phase) {
        case (.listening, .sending), (.transcribing, .sending):
            model.collapse()
            if panel == nil { createPanel() }
            isNotchDockRevealed = true
            syncNotchDockPresentation()
            panel?.orderFrontRegardless()
            reposition()
            updateNotchScreenFollowTimer()
        default:
            break
        }
    }

    private func handlePermissionRequestChange(_ request: AssistantPermissionRequest?) {
        guard isEnabled else { return }
        if presentationStyle == .notch {
            if request != nil {
                if panel == nil { createPanel() }
                preserveCurrentNotchScreenAsPreferredDisplay()
                isNotchDockRevealed = true
                syncNotchDockPresentation()
                syncNotchPermissionTextEntry()
                reposition()
                panel?.orderFrontRegardless()
            } else if !model.isExpanded {
                reposition()
            }
            updateNotchScreenFollowTimer()
            return
        }

        guard !model.isExpanded else { return }
        reposition()
        if let request {
            if panel == nil { createPanel() }
            if request.hasStructuredUserInput {
                panel?.allowsKeyStatus = true
                panel?.makeKeyAndOrderFront(nil)
            } else {
                panel?.allowsKeyStatus = false
                panel?.orderFrontRegardless()
            }
            startClickOutsideMonitor()
        } else {
            panel?.allowsKeyStatus = false
            stopClickOutsideMonitor()
        }
    }

    private func handleModeSwitchSuggestionChange(_ suggestion: AssistantModeSwitchSuggestion?) {
        guard isEnabled else { return }
        if presentationStyle == .notch {
            if suggestion != nil {
                if panel == nil { createPanel() }
                preserveCurrentNotchScreenAsPreferredDisplay()
                isNotchDockRevealed = true
                syncNotchDockPresentation()
                reposition()
                panel?.orderFrontRegardless()
            } else if !model.isExpanded {
                reposition()
            }
            updateNotchScreenFollowTimer()
            return
        }
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
        updateNotchScreenFollowTimer()
    }

    private func startClickOutsideMonitor() {
        stopClickOutsideMonitor()
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.presentationStyle == .notch {
                    guard self.model.isExpanded else { return }
                } else {
                    guard self.model.isExpanded || self.model.showDoneDetail || self.model.showWorkingDetail else { return }
                }
                if let panel = self.panel, panel.frame.contains(NSEvent.mouseLocation) {
                    return
                }
                if self.model.isExpanded {
                    if self.presentationStyle == .notch {
                        self.model.collapseExpandedTray()
                    } else {
                        self.model.collapse()
                    }
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

    private func scheduleAutoDismissIfNeeded(for state: AssistantHUDState) {
        guard presentationStyle == .notch else { return }
        _ = state
    }

    private var notchDockRevealDelay: TimeInterval {
        settings.assistantNotchHoverDelay.seconds
    }

    private func handleDisplayEnvironmentChange() {
        guard isEnabled,
              presentationStyle == .notch,
              let panel,
              panel.isVisible else {
            return
        }

        notchDockHideDeadline = nil
        notchDockRevealHoverState = AssistantNotchInteraction.HoverState()
        suppressNotchDockRevealUntilPointerLeaves = false

        if !model.isExpanded {
            captureMouseScreenAsPreferredDisplay()
        } else if screenForPreferredDisplay() == nil {
            preserveCurrentNotchScreenAsPreferredDisplay()
        }

        panel.ignoresMouseEvents = false
        reposition()
        panel.orderFrontRegardless()
        updateNotchScreenFollowTimer()
    }

    private func updateNotchScreenFollowTimer() {
        stopNotchScreenFollowTimer()

        guard presentationStyle == .notch,
              panel?.isVisible == true,
              !model.isExpanded else {
            return
        }

        let timer = Timer(timeInterval: Layout.notchScreenFollowInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.followMouseScreenIfNeeded()
            }
        }
        notchScreenFollowTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopNotchScreenFollowTimer() {
        notchScreenFollowTimer?.invalidate()
        notchScreenFollowTimer = nil
        notchDockHideDeadline = nil
    }

    private func followMouseScreenIfNeeded() {
        guard isEnabled,
              presentationStyle == .notch,
              panel?.isVisible == true,
              !model.isExpanded,
              let targetScreen = Self.screenContainingMouse(),
              let targetDisplayID = Self.displayID(for: targetScreen) else {
            return
        }

        let currentDisplayID = panel?.screen.flatMap(Self.displayID(for:))
        let currentScreen = panel?.screen ?? screenForPreferredDisplay()
        let isShowingCompactCard = model.pendingPermissionRequest != nil
            || model.showDoneDetail
            || model.showWorkingDetail
            || model.modeSwitchSuggestion != nil
            || model.showCompactComposer

        if isShowingCompactCard {
            notchDockRevealHoverState = AssistantNotchInteraction.HoverState()
            syncPanelMouseBehavior()
            return
        }

        if currentDisplayID == targetDisplayID || currentDisplayID == nil {
            let wasRevealed = isNotchDockRevealed
            updateNotchDockState(for: targetScreen)

            guard currentDisplayID != targetDisplayID
                || preferredDisplayID != targetDisplayID
                || wasRevealed != isNotchDockRevealed else {
                return
            }

            preferredDisplayID = targetDisplayID
            reposition()
            return
        }

        if let currentScreen {
            let wasRevealed = isNotchDockRevealed
            updateNotchDockState(for: currentScreen)
            if wasRevealed != isNotchDockRevealed {
                preferredDisplayID = currentDisplayID
                reposition()
            }
        }

        let mouseLocation = NSEvent.mouseLocation
        if shouldSuppressNotchDockReveal(for: targetScreen, mouseLocation: mouseLocation) {
            return
        }

        guard shouldDockCollapsedNotch,
              notchRevealZone(for: targetScreen).contains(mouseLocation) else {
            return
        }

        isNotchDockRevealed = true
        notchDockHideDeadline = nil
        syncNotchDockPresentation()
        preferredDisplayID = targetDisplayID
        reposition()
    }

    private func updateNotchDockState(for screen: NSScreen) {
        guard shouldDockCollapsedNotch else {
            if isNotchDockRevealed {
                isNotchDockRevealed = false
                syncNotchDockPresentation(for: screen)
            }
            notchDockHideDeadline = nil
            notchDockRevealHoverState = AssistantNotchInteraction.HoverState()
            suppressNotchDockRevealUntilPointerLeaves = false
            return
        }

        let mouseLocation = NSEvent.mouseLocation
        let isMouseButtonDown = NSEvent.pressedMouseButtons != 0
        let revealZone = notchRevealZone(for: screen)
        let revealedFrame = notchFrame(for: screen, dockRevealed: true)
        let interactionZone = revealedFrame.insetBy(dx: -12, dy: -10)

        if shouldSuppressNotchDockReveal(
            revealZone: revealZone,
            interactionZone: interactionZone,
            mouseLocation: mouseLocation
        ) {
            if isNotchDockRevealed {
                isNotchDockRevealed = false
                syncNotchDockPresentation(for: screen)
            }
            notchDockHideDeadline = nil
            notchDockRevealHoverState = AssistantNotchInteraction.HoverState()
            return
        }

        let isHoveringDock = revealZone.contains(mouseLocation) || interactionZone.contains(mouseLocation)
        let canAutoHideIdleDock = model.state.phase == .idle
        let hoveredDisplayID = Self.displayID(for: screen)
        let now = Date()

        notchDockRevealHoverState = AssistantNotchInteraction.updatedHoverState(
            current: notchDockRevealHoverState,
            hoveredDisplayID: hoveredDisplayID,
            isEligible: isHoveringDock && !isMouseButtonDown,
            now: now
        )

        if isHoveringDock {
            guard AssistantNotchInteraction.shouldReveal(
                hoverStart: notchDockRevealHoverState.start,
                now: now,
                revealDelay: notchDockRevealDelay
            ) else {
                notchDockHideDeadline = nil
                syncPanelMouseBehavior()
                return
            }

            isNotchDockRevealed = true
            notchDockHideDeadline = nil
            syncNotchDockPresentation(for: screen)
            return
        }

        notchDockRevealHoverState = AssistantNotchInteraction.HoverState()

        guard canAutoHideIdleDock, isNotchDockRevealed else {
            notchDockHideDeadline = nil
            syncPanelMouseBehavior()
            return
        }

        if let deadline = notchDockHideDeadline {
            guard now >= deadline else { return }
            isNotchDockRevealed = false
            notchDockHideDeadline = nil
            syncNotchDockPresentation(for: screen)
        } else {
            notchDockHideDeadline = now.addingTimeInterval(Layout.notchDockHideDelay)
        }
    }

    private func syncNotchDockPresentation() {
        syncNotchDockPresentation(for: panel?.screen ?? screenForPreferredDisplay() ?? NSScreen.main)
    }

    private func syncNotchDockPresentation(for screen: NSScreen?) {
        model.notchDockRevealed = isNotchDockRevealed
        if let screen {
            let anchorMode = notchAnchorMode(for: screen)
            switch anchorMode {
            case let .hardwareNotch(gapRect):
                model.notchUsesHardwareOutline = true
                model.notchHardwareOutlineSize = gapRect.size
                model.notchDockVisibleWidth = gapRect.width
                model.notchDockVisibleHeight = notchDockVisibleHeight(for: screen)
            case .syntheticNotch:
                model.notchUsesHardwareOutline = false
                model.notchHardwareOutlineSize = .zero
                model.notchDockVisibleWidth = 160
                model.notchDockVisibleHeight = notchDockVisibleHeight(for: screen)
            }
        } else {
            model.notchUsesHardwareOutline = false
            model.notchHardwareOutlineSize = .zero
            model.notchDockVisibleWidth = 160
            model.notchDockVisibleHeight = Layout.notchDockHiddenVisibleHeight
        }
        syncPanelMouseBehavior()
    }

    private var isShowingNotchCompactCard: Bool {
        model.pendingPermissionRequest != nil
            || model.showDoneDetail
            || model.showWorkingDetail
            || model.modeSwitchSuggestion != nil
            || model.showCompactComposer
    }

    private func syncPanelMouseBehavior() {
        guard let panel else { return }
        guard presentationStyle == .notch else {
            panel.ignoresMouseEvents = false
            return
        }

        panel.ignoresMouseEvents = AssistantNotchInteraction.shouldAllowMousePassthrough(
            isDockRevealed: isNotchDockRevealed,
            shouldDockCollapsed: shouldDockCollapsedNotch,
            isShowingCompactCard: isShowingNotchCompactCard,
            isExpanded: model.isExpanded
        )
    }

    private func activatePopupTextEntry() {
        guard presentationStyle == .orb else { return }
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

    private func syncNotchCompactTextEntry() {
        guard presentationStyle == .notch else { return }
        guard !model.isExpanded else { return }

        let needsKeyEntry = model.showDoneDetail
            || model.showWorkingDetail
            || model.showCompactComposer
            || (model.pendingPermissionRequest?.hasStructuredUserInput == true)
        guard needsKeyEntry else {
            model.shouldFocusTextField = false
            panel?.allowsKeyStatus = false
            return
        }

        if panel == nil { createPanel() }
        panel?.allowsKeyStatus = true
        if model.showCompactComposer {
            NSApp.activate(ignoringOtherApps: true)
        }
        panel?.makeKeyAndOrderFront(nil)

        let shouldAutoFocus = model.showDoneDetail || model.showCompactComposer
        guard shouldAutoFocus else {
            model.shouldFocusTextField = false
            return
        }

        model.shouldFocusTextField = false
        DispatchQueue.main.async { [weak self] in
            guard let self, self.presentationStyle == .notch, !self.model.isExpanded else { return }
            guard self.model.showDoneDetail || self.model.showCompactComposer || self.model.pendingPermissionRequest?.hasStructuredUserInput == true else { return }
            self.model.shouldFocusTextField = true
        }
    }

    private func syncNotchPermissionTextEntry() {
        guard presentationStyle == .notch else { return }
        guard !model.isExpanded else { return }
        guard model.pendingPermissionRequest?.hasStructuredUserInput == true else { return }

        if panel == nil { createPanel() }
        panel?.allowsKeyStatus = true
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)

        model.shouldFocusTextField = false
        DispatchQueue.main.async { [weak self] in
            guard let self, self.presentationStyle == .notch, !self.model.isExpanded else { return }
            guard self.model.pendingPermissionRequest?.hasStructuredUserInput == true else { return }
            self.model.shouldFocusTextField = true
        }
    }

    private func deactivatePopupTextEntry() {
        guard presentationStyle == .orb else { return }
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
        model.canStopActiveTurn = controller.hasActiveTurn
        model.liveVoiceSnapshot = controller.liveVoiceSessionSnapshot
        model.isVoiceRecording = controller.liveVoiceSessionSnapshot.isListening
        model.update(state: effectiveDisplayState(for: controller.hudState))
        model.updatePreviewImages(latestTimelineImageAttachments())
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

    private func effectiveDisplayState(for state: AssistantHUDState) -> AssistantHUDState {
        let displayState = displayState(for: state)
        if Self.shouldUseLiveVoiceDisplayState(
            controller.liveVoiceSessionSnapshot,
            over: displayState
        ), let liveVoiceState = liveVoiceDisplayState(from: controller.liveVoiceSessionSnapshot) {
            return liveVoiceState
        }
        return displayState
    }

    static func shouldUseLiveVoiceDisplayState(
        _ snapshot: AssistantLiveVoiceSessionSnapshot,
        over hudState: AssistantHUDState
    ) -> Bool {
        switch snapshot.phase {
        case .idle, .ended:
            return false
        case .listening, .transcribing, .sending, .waitingForPermission, .speaking, .paused:
            return true
        }
    }

    private func liveVoiceDisplayState(
        from snapshot: AssistantLiveVoiceSessionSnapshot
    ) -> AssistantHUDState? {
        switch snapshot.phase {
        case .idle:
            return nil
        case .listening:
            return AssistantHUDState(
                phase: .listening,
                title: "Listening",
                detail: snapshot.displayText
            )
        case .transcribing:
            return AssistantHUDState(
                phase: .thinking,
                title: "Transcribing",
                detail: snapshot.displayText
            )
        case .sending:
            return AssistantHUDState(
                phase: .acting,
                title: snapshot.interactionMode == .agentic ? "Agentic" : "Sending",
                detail: snapshot.displayText
            )
        case .waitingForPermission:
            return AssistantHUDState(
                phase: .waitingForPermission,
                title: "Waiting for approval",
                detail: snapshot.displayText
            )
        case .speaking:
            return AssistantHUDState(
                phase: .streaming,
                title: "Speaking",
                detail: snapshot.displayText
            )
        case .paused:
            if snapshot.isHandsFreeLoopEnabled,
               snapshot.lastError?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty == nil {
                return AssistantHUDState(
                    phase: .thinking,
                    title: "Re-arming",
                    detail: snapshot.displayText
                )
            }
            return AssistantHUDState(
                phase: .idle,
                title: "Paused",
                detail: snapshot.displayText
            )
        case .ended:
            return AssistantHUDState(
                phase: .idle,
                title: "Conversation ended",
                detail: snapshot.displayText
            )
        }
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

    private func latestTimelineImageAttachments() -> [Data] {
        let visibleItems = controller.timelineItems
        let anchorText = model.doneDetailText?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? controller.hudState.detail?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty

        return assistantTimelineImageAttachments(
            matchingReplyText: anchorText,
            in: visibleItems
        )
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
        if panelSize.width > Layout.orbCollapsedSize.width || panelSize.height > Layout.orbCollapsedSize.height {
            let collapsedX = panelOrigin.x + ((panelSize.width - Layout.orbCollapsedSize.width) / 2)
            let collapsedY = isOrbAnchoredAtBottom
                ? panelOrigin.y
                : panelOrigin.y + (panelSize.height - Layout.orbCollapsedSize.height)
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
        if presentationStyle == .notch {
            return screenForPreferredDisplay()
                ?? panel.screen
                ?? Self.screenContainingMouse()
                ?? NSScreen.main
                ?? NSScreen.screens.first
        }

        if let panelScreen = panel.screen {
            return panelScreen
        }

        if presentationStyle == .orb, let saved = savedOrigin {
            let collapsedFrame = NSRect(origin: saved, size: Layout.orbCollapsedSize)
            if let matchingScreen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(collapsedFrame) }) {
                return matchingScreen
            }
        }

        return screenForPreferredDisplay() ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func screenForPreferredDisplay() -> NSScreen? {
        guard let preferredDisplayID else { return nil }
        return NSScreen.screens.first(where: { Self.displayID(for: $0) == preferredDisplayID })
    }

    private func captureMouseScreenAsPreferredDisplay() {
        guard let screen = Self.screenContainingMouse(),
              let displayID = Self.displayID(for: screen) else {
            return
        }
        preferredDisplayID = displayID
    }

    private func preserveCurrentNotchScreenAsPreferredDisplay() {
        if let screen = panel?.screen ?? screenForPreferredDisplay(),
           let displayID = Self.displayID(for: screen) {
            preferredDisplayID = displayID
            return
        }

        captureMouseScreenAsPreferredDisplay()
    }

    private func notchFrame(for screen: NSScreen) -> NSRect {
        notchFrame(for: screen, dockRevealed: isNotchDockRevealed)
    }

    private func notchFrame(for screen: NSScreen, dockRevealed: Bool) -> NSRect {
        var requestedSize = targetSize
        // When the caller requests the "revealed" geometry (used for interaction-zone
        // calculations) but the model is currently in the hidden idle state, substitute
        // the collapsed-pill size so the zone covers the actual visible pill area.
        if dockRevealed, presentationStyle == .notch, !model.isExpanded, !model.notchDockRevealed,
           model.pendingPermissionRequest == nil, !model.showDoneDetail, !model.showWorkingDetail,
           !model.showCompactComposer, model.modeSwitchSuggestion == nil {
            requestedSize = Layout.notchCollapsedSize
        }
        let clampedWidth = min(requestedSize.width, max(480, screen.frame.width - 48))
        let hiddenHeight = notchDockVisibleHeight(for: screen)
        let verticalOffset = notchVerticalOffset(
            for: screen,
            requestedSize: requestedSize,
            hiddenHeight: hiddenHeight,
            dockRevealed: dockRevealed
        )
        let clampedHeight = min(requestedSize.height, max(44, screen.frame.height - verticalOffset - 48))
        let size = NSSize(width: clampedWidth, height: clampedHeight)
        // Keep every notch state centered on the display horizontally.
        // The hardware gap APIs are good for sizing and vertical placement,
        // but they can drift enough to make the pop-up look like it jumps sideways.
        let originX = AssistantNotchLayout.centeredOriginX(screenFrame: screen.frame, width: size.width)
        let originY = round(screen.frame.maxY - verticalOffset - size.height)
        return NSRect(origin: NSPoint(x: originX, y: originY), size: size)
    }

    private var shouldDockCollapsedNotch: Bool {
        presentationStyle == .notch
            && !model.isExpanded
            && model.pendingPermissionRequest == nil
            && !model.showDoneDetail
            && !model.showWorkingDetail
            && model.modeSwitchSuggestion == nil
            && !model.showCompactComposer
    }

    private func notchDockVisibleHeight(for screen: NSScreen) -> CGFloat {
        switch notchAnchorMode(for: screen) {
        case let .hardwareNotch(gapRect):
            return calibratedHardwareNotchHeight(for: screen, topBandHeight: gapRect.height)
        case .syntheticNotch:
            return Layout.notchDockHiddenVisibleHeight
        }
    }

    private func calibratedHardwareNotchHeight(for screen: NSScreen, topBandHeight: CGFloat) -> CGFloat {
        let scale = max(screen.backingScaleFactor, 1)
        let topBandPixels = topBandHeight * scale

        let housingPixels: CGFloat
        if topBandPixels >= 72 {
            // Online measurements for notched MacBook Pro models commonly place
            // the full top band at 74 px and the camera housing itself at 64 px.
            housingPixels = 64
        } else if topBandPixels >= 62 {
            // Online measurements for notch MacBook Air models commonly place
            // the full top band around 64 px. We keep the housing a bit shorter
            // so the outline stays inside the visible camera area.
            housingPixels = 54
        } else {
            housingPixels = max(24, topBandPixels - 10)
        }

        return max(16, housingPixels / scale)
    }

    private func notchRevealZone(for screen: NSScreen) -> NSRect {
        let hiddenFrame = notchFrame(for: screen, dockRevealed: false)
        let horizontalPadding = max(
            Layout.notchDockHoverPadding,
            (Layout.notchCollapsedSize.width - hiddenFrame.width) / 2
        )
        let verticalPadding = max(
            Layout.notchDockHoverPadding,
            (Layout.notchCollapsedSize.height - hiddenFrame.height) / 2
        )
        return AssistantNotchLayout.revealZone(
            for: hiddenFrame,
            horizontalPadding: horizontalPadding,
            minimumHoverHeight: max(Layout.notchDockHoverBandHeight, Layout.notchCollapsedSize.height),
            verticalPadding: verticalPadding
        )
    }

    private func shouldSuppressNotchDockReveal(for screen: NSScreen, mouseLocation: NSPoint) -> Bool {
        let revealZone = notchRevealZone(for: screen)
        let interactionZone = notchFrame(for: screen, dockRevealed: true).insetBy(dx: -12, dy: -10)
        return shouldSuppressNotchDockReveal(
            revealZone: revealZone,
            interactionZone: interactionZone,
            mouseLocation: mouseLocation
        )
    }

    private func shouldSuppressNotchDockReveal(
        revealZone: NSRect,
        interactionZone: NSRect,
        mouseLocation: NSPoint
    ) -> Bool {
        guard suppressNotchDockRevealUntilPointerLeaves else { return false }

        if revealZone.contains(mouseLocation) || interactionZone.contains(mouseLocation) {
            return true
        }

        suppressNotchDockRevealUntilPointerLeaves = false
        return false
    }

    private func notchVerticalOffset(
        for screen: NSScreen,
        requestedSize: NSSize,
        hiddenHeight: CGFloat,
        dockRevealed: Bool
    ) -> CGFloat {
        let visibleTopInset = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
        let requestedHeight = dockRevealed
            ? max(requestedSize.height, Layout.notchCollapsedSize.height)
            : requestedSize.height

        switch notchAnchorMode(for: screen) {
        case let .hardwareNotch(gapRect):
            return AssistantNotchLayout.verticalOffset(
                topBandHeight: gapRect.height,
                safeAreaTop: screen.safeAreaInsets.top,
                visibleTopInset: visibleTopInset,
                hiddenHeight: hiddenHeight,
                requestedHeight: requestedHeight,
                spacingBelowNotch: Layout.notchBelowCameraSpacing
            )
        case .syntheticNotch:
            // Fall back to the screen's visible frame when the hardware-notch APIs
            // are unavailable or do not look trustworthy. This keeps pop-up content
            // below the menu bar/top safe area instead of letting it hide under it.
            return AssistantNotchLayout.verticalOffset(
                topBandHeight: 0,
                safeAreaTop: screen.safeAreaInsets.top,
                visibleTopInset: visibleTopInset,
                hiddenHeight: hiddenHeight,
                requestedHeight: requestedHeight,
                spacingBelowNotch: Layout.notchBelowCameraSpacing
            )
        }
    }

    private func notchAnchorMode(for screen: NSScreen) -> NotchAnchorMode {
        guard let gapRect = notchGapRect(for: screen) else {
            return .syntheticNotch
        }
        return .hardwareNotch(gapRect)
    }

    private func notchGapRect(for screen: NSScreen) -> NSRect? {
        guard let leftArea = screen.auxiliaryTopLeftArea,
              let rightArea = screen.auxiliaryTopRightArea,
              screen.safeAreaInsets.top > 0,
              leftArea.width > 0,
              rightArea.width > 0,
              normalizedHorizontalCoordinate(rightArea.minX, on: screen)
                > normalizedHorizontalCoordinate(leftArea.maxX, on: screen) else {
            return nil
        }

        let leftMaxX = normalizedHorizontalCoordinate(leftArea.maxX, on: screen)
        let rightMinX = normalizedHorizontalCoordinate(rightArea.minX, on: screen)
        let notchWidth = max(0, rightMinX - leftMaxX)
        guard notchWidth > 0 else { return nil }

        let gapMidX = leftMaxX + (notchWidth / 2)
        let screenMidX = screen.frame.midX
        let maxAllowedGapWidth = screen.frame.width * 0.3
        let maxAllowedCenterDrift = min(48.0, screen.frame.width * 0.03)

        // Normal external displays can still expose auxiliary top areas.
        // Only use them when the gap looks like a real centered camera notch.
        guard notchWidth <= maxAllowedGapWidth,
              abs(gapMidX - screenMidX) <= maxAllowedCenterDrift else {
            return nil
        }

        return NSRect(
            x: leftMaxX,
            y: max(
                normalizedVerticalCoordinate(leftArea.minY, on: screen),
                normalizedVerticalCoordinate(rightArea.minY, on: screen)
            ),
            width: notchWidth,
            height: max(leftArea.height, rightArea.height)
        )
    }

    private func normalizedHorizontalCoordinate(_ value: CGFloat, on screen: NSScreen) -> CGFloat {
        if value >= (screen.frame.minX - 1), value <= (screen.frame.maxX + 1) {
            return value
        }
        return screen.frame.minX + value
    }

    private func normalizedVerticalCoordinate(_ value: CGFloat, on screen: NSScreen) -> CGFloat {
        if value >= (screen.frame.minY - 1), value <= (screen.frame.maxY + 1) {
            return value
        }
        return screen.frame.minY + value
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }

    private static func screenContainingMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
    }

}

typealias AssistantOrbHUDManager = AssistantCompactHUDManager

// MARK: - Key-capable Panel with native drag

private class OrbHUDPanel: NSPanel {
    var allowsKeyStatus = false
    var onPositionPersist: (() -> Void)?
    var allowsOrbDrag = true
    /// When true, the orb sits at the bottom of the panel. Drag zone moves to bottom.
    var isOrbAnchoredAtBottom = false

    /// Height of the orb area that initiates dragging.
    private let orbAreaHeight: CGFloat = 120
    private let dragThreshold: CGFloat = 4

    private var dragStartScreenLocation: NSPoint?
    private var dragStartOrigin: NSPoint?
    private var isWindowDragging = false

    override var canBecomeKey: Bool { allowsKeyStatus }
    override var canBecomeMain: Bool { allowsKeyStatus }

    /// Check if click is in the orb drag zone.
    /// When the orb is bottom-anchored, drag from the lower orb area.
    /// Otherwise, drag from the upper orb area.
    private func isInOrbDragZone(_ loc: NSPoint) -> Bool {
        guard allowsOrbDrag else { return false }
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
