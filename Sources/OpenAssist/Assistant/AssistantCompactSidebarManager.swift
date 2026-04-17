import AppKit
import Combine
import SwiftUI

@MainActor
final class AssistantCompactSurfaceCoordinator: AssistantCompactPresenter {
    private let controller: AssistantStore
    private let settings: SettingsStore

    private var presenter: AssistantCompactPresenter
    private var style: AssistantCompactPresentationStyle
    private var preferredScreen: NSScreen?
    private var latestHUDState: AssistantHUDState
    private var latestAudioLevel: Float = 0
    private var isVoiceRecording = false

    init(
        controller: AssistantStore,
        settings: SettingsStore,
        style: AssistantCompactPresentationStyle = .orb
    ) {
        self.controller = controller
        self.settings = settings
        self.style = style
        self.latestHUDState = controller.hudState
        self.presenter = Self.makePresenter(
            style: style,
            controller: controller,
            settings: settings
        )
    }

    var isEnabled = true {
        didSet {
            presenter.isEnabled = isEnabled
            if isEnabled {
                presenter.update(state: latestHUDState)
                presenter.updateLevel(latestAudioLevel)
                presenter.setVoiceRecording(isVoiceRecording)
            }
        }
    }

    var currentScreen: NSScreen? {
        presenter.currentScreen
    }

    var isExpandedSurfaceVisible: Bool {
        presenter.isExpandedSurfaceVisible
    }

    func setPresentationStyle(_ style: AssistantCompactPresentationStyle) {
        guard style != self.style else {
            presenter.setPresentationStyle(style)
            return
        }

        presenter.hide()
        presenter.isEnabled = false

        self.style = style
        presenter = Self.makePresenter(style: style, controller: controller, settings: settings)
        presenter.isEnabled = isEnabled
        if let preferredScreen {
            presenter.setPreferredScreen(preferredScreen)
        }
        presenter.setPresentationStyle(style)
        if isEnabled {
            presenter.update(state: latestHUDState)
            presenter.updateLevel(latestAudioLevel)
            presenter.setVoiceRecording(isVoiceRecording)
        }
    }

    func setPreferredScreen(_ screen: NSScreen?) {
        preferredScreen = screen
        presenter.setPreferredScreen(screen)
    }

    func prepareVoiceCaptureComposer() {
        presenter.prepareVoiceCaptureComposer()
    }

    func showFollowUp(for session: AssistantSessionSummary) {
        presenter.showFollowUp(for: session)
    }

    func collapseExpandedSurface() {
        presenter.collapseExpandedSurface()
    }

    func update(state: AssistantHUDState) {
        latestHUDState = state
        presenter.update(state: state)
    }

    func updateLevel(_ level: Float) {
        latestAudioLevel = level
        presenter.updateLevel(level)
    }

    func setVoiceRecording(_ isRecording: Bool) {
        isVoiceRecording = isRecording
        presenter.setVoiceRecording(isRecording)
    }

    func receiveVoiceTranscript(_ text: String) {
        presenter.receiveVoiceTranscript(text)
    }

    func hide() {
        presenter.hide()
    }

    private static func makePresenter(
        style: AssistantCompactPresentationStyle,
        controller: AssistantStore,
        settings: SettingsStore
    ) -> AssistantCompactPresenter {
        switch style {
        case .orb, .notch:
            return AssistantCompactHUDManager(
                controller: controller,
                settings: settings,
                style: style
            )
        case .sidebar:
            return AssistantCompactSidebarManager(
                controller: controller,
                settings: settings
            )
        }
    }
}

@MainActor
final class AssistantCompactSidebarManager: AssistantCompactPresenter {
    private enum Layout {
        static let handleWidth: CGFloat = 18
        static let screenInset: CGFloat = 2
        static let cornerRadius: CGFloat = 28
        static let minimumPanelHeight: CGFloat = 420
        static let minimumContentWidth: CGFloat = 560
        static let preferredContentWidth: CGFloat = 760
        static let maximumContentWidthFraction: CGFloat = 0.56
        static let screenFollowInterval: TimeInterval = 0.25
        static let screenSwitchActivationWidth: CGFloat = 56
        static let openAnimationDuration: TimeInterval = 0.24
        static let closeAnimationDuration: TimeInterval = 0.18
    }

    private final class SidebarPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    final class ViewModel: ObservableObject {
        @Published var isOpen = false
        @Published var hudState: AssistantHUDState = .idle
        @Published var audioLevel: Float = 0
        @Published var isVoiceRecording = false
        @Published var contentWidth: CGFloat = Layout.preferredContentWidth
    }

    private let controller: AssistantStore
    private let settings: SettingsStore
    private let viewModel = ViewModel()

    private var panel: SidebarPanel?
    private var preferredDisplayID: CGDirectDisplayID?
    private var clickOutsideMonitor: Any?
    private var localClickMonitor: Any?
    private var localKeyMonitor: Any?
    private var screenFollowTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    init(controller: AssistantStore, settings: SettingsStore) {
        self.controller = controller
        self.settings = settings

        settings.$assistantCompactSidebarEdgeRawValue
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.isEnabled else { return }
                self.ensurePanelVisible(animated: true)
            }
            .store(in: &cancellables)
    }

    var isEnabled = true {
        didSet {
            if isEnabled {
                ensurePanelVisible(animated: false)
                updateScreenFollowTimer()
            } else {
                hide()
            }
        }
    }

    var currentScreen: NSScreen? {
        if let panelScreen = panel?.screen {
            return panelScreen
        }
        return screenForPreferredDisplay()
    }

    var isExpandedSurfaceVisible: Bool {
        viewModel.isOpen
    }

    func setPresentationStyle(_ style: AssistantCompactPresentationStyle) {
        guard style == .sidebar else {
            hide()
            return
        }
        if isEnabled {
            ensurePanelVisible(animated: false)
        }
    }

    func setPreferredScreen(_ screen: NSScreen?) {
        preferredDisplayID = Self.displayID(for: screen)
        if panel != nil {
            ensurePanelVisible(animated: false)
        }
        updateScreenFollowTimer()
    }

    func prepareVoiceCaptureComposer() {
        openPanel(makeKey: true)
    }

    func showFollowUp(for session: AssistantSessionSummary) {
        controller.selectedSessionID = session.id
        openPanel(makeKey: true)
    }

    func collapseExpandedSurface() {
        closePanel()
    }

    func update(state: AssistantHUDState) {
        viewModel.hudState = state
        guard isEnabled else { return }
        ensurePanelVisible(animated: false)
        if state.phase == .waitingForPermission {
            openPanel(makeKey: true)
        }
    }

    func updateLevel(_ level: Float) {
        viewModel.audioLevel = level
    }

    func setVoiceRecording(_ isRecording: Bool) {
        viewModel.isVoiceRecording = isRecording
        if isRecording {
            openPanel(makeKey: true)
        }
    }

    func receiveVoiceTranscript(_ text: String) {
        viewModel.isVoiceRecording = false
        viewModel.audioLevel = 0

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        openPanel(makeKey: true)

        if !AssistantComposerBridge.shared.insert(trimmed) {
            controller.receiveVoiceDraft(trimmed)
        } else {
            // Bridge handled insertion; reset HUD from .listening → .idle
            controller.showTransientHUDState(.idle)
        }
    }

    func hide() {
        viewModel.isOpen = false
        stopOutsideClickMonitor()
        stopLocalClickMonitor()
        stopKeyMonitor()
        stopScreenFollowTimer()
        panel?.orderOut(nil)
    }

    private func ensurePanelVisible(animated: Bool) {
        guard isEnabled else { return }
        if panel == nil {
            createPanel()
        }
        reposition(animated: animated)
        panel?.orderFrontRegardless()
    }

    private func openPanel(makeKey: Bool) {
        if !viewModel.isOpen {
            captureMouseScreenAsPreferredDisplay()
        }
        viewModel.isOpen = true
        ensurePanelVisible(animated: true)
        startOutsideClickMonitor()
        startLocalClickMonitor()
        startKeyMonitor()
        updateScreenFollowTimer()
        if makeKey {
            NSApp.activate(ignoringOtherApps: true)
            panel?.makeKeyAndOrderFront(nil)
        }
    }

    private func closePanel() {
        guard viewModel.isOpen else { return }
        viewModel.isOpen = false
        stopOutsideClickMonitor()
        stopLocalClickMonitor()
        stopKeyMonitor()
        ensurePanelVisible(animated: true)
        updateScreenFollowTimer()
    }

    private func createPanel() {
        let screen = screenForPreferredDisplay() ?? Self.screenContainingMouse() ?? NSScreen.main
        let initialFrame = panelFrame(for: screen, isOpen: viewModel.isOpen)

        let panel = SidebarPanel(
            contentRect: initialFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.ignoresMouseEvents = false

        let hostingController = NSHostingController(
            rootView: AssistantCompactSidebarRootView(
                assistant: controller,
                settings: settings,
                viewModel: viewModel,
                onToggleOpen: { [weak self] in
                    guard let self else { return }
                    if self.viewModel.isOpen {
                        self.closePanel()
                    } else {
                        self.openPanel(makeKey: true)
                    }
                },
                onMoveEdge: { [weak self] edge in
                    guard let self else { return }
                    self.settings.assistantCompactSidebarEdge = edge
                    self.ensurePanelVisible(animated: true)
                },
                onOpenFullAssistant: {
                    NotificationCenter.default.post(name: .openAssistOpenAssistant, object: nil)
                }
            )
            .environmentObject(settings)
        )
        hostingController.sizingOptions = []
        panel.contentViewController = hostingController

        self.panel = panel
    }

    private func reposition(animated: Bool) {
        guard let panel else { return }
        let screen = screenForPreferredDisplay() ?? NSScreen.main
        let frame = panelFrame(for: screen, isOpen: viewModel.isOpen)
        preferredDisplayID = Self.displayID(for: screen)
        guard animated else {
            panel.setFrame(frame, display: true)
            return
        }

        let duration = viewModel.isOpen
            ? Layout.openAnimationDuration
            : Layout.closeAnimationDuration

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(frame, display: true)
        }
    }

    private func panelFrame(for screen: NSScreen?, isOpen: Bool) -> NSRect {
        let visibleFrame = (screen ?? NSScreen.main)?.visibleFrame ?? NSRect(
            x: 0,
            y: 0,
            width: 1440,
            height: 900
        )
        let availableContentWidth = max(
            1,
            visibleFrame.width - (Layout.screenInset * 2) - Layout.handleWidth
        )
        let desiredContentWidth = min(
            Layout.preferredContentWidth,
            max(
                Layout.minimumContentWidth,
                visibleFrame.width * Layout.maximumContentWidthFraction
            )
        )
        let contentWidth = min(desiredContentWidth, availableContentWidth)
        if abs(viewModel.contentWidth - contentWidth) > 0.5 {
            viewModel.contentWidth = contentWidth
        }
        let totalWidth = contentWidth + Layout.handleWidth
        let availableHeight = max(1, visibleFrame.height - (Layout.screenInset * 2))
        let height = min(
            Layout.minimumPanelHeight,
            visibleFrame.height
        )
        let resolvedHeight = max(height, min(availableHeight, visibleFrame.height))
        let y = visibleFrame.minY + max(0, (visibleFrame.height - resolvedHeight) / 2)

        switch settings.assistantCompactSidebarEdge {
        case .left:
            let openX = visibleFrame.minX + Layout.screenInset
            let closedX = openX
            return NSRect(
                x: isOpen ? openX : closedX,
                y: y,
                width: isOpen ? totalWidth : Layout.handleWidth,
                height: resolvedHeight
            )
        case .right:
            let openX = visibleFrame.maxX - Layout.screenInset - totalWidth
            let closedX = visibleFrame.maxX - Layout.screenInset - Layout.handleWidth
            return NSRect(
                x: isOpen ? openX : closedX,
                y: y,
                width: isOpen ? totalWidth : Layout.handleWidth,
                height: resolvedHeight
            )
        }
    }

    private func screenForPreferredDisplay() -> NSScreen? {
        guard let preferredDisplayID else {
            return Self.screenContainingMouse() ?? NSScreen.main
        }
        return NSScreen.screens.first { Self.displayID(for: $0) == preferredDisplayID }
            ?? Self.screenContainingMouse()
            ?? NSScreen.main
    }

    private func startOutsideClickMonitor() {
        guard clickOutsideMonitor == nil else { return }
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.closePanelIfNeededForOutsideClick()
            }
        }
    }

    private func stopOutsideClickMonitor() {
        if let clickOutsideMonitor {
            NSEvent.removeMonitor(clickOutsideMonitor)
            self.clickOutsideMonitor = nil
        }
    }

    private func startLocalClickMonitor() {
        guard localClickMonitor == nil else { return }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            self?.closePanelIfNeededForOutsideClick()
            return event
        }
    }

    private func stopLocalClickMonitor() {
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
            self.localClickMonitor = nil
        }
    }

    private func startKeyMonitor() {
        guard localKeyMonitor == nil else { return }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.viewModel.isOpen else { return event }
            if event.keyCode == 53 {
                self.closePanel()
                return nil
            }
            return event
        }
    }

    private func stopKeyMonitor() {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
    }

    private func updateScreenFollowTimer() {
        if isEnabled && !viewModel.isOpen {
            startScreenFollowTimerIfNeeded()
        } else {
            stopScreenFollowTimer()
        }
    }

    private func startScreenFollowTimerIfNeeded() {
        guard screenFollowTimer == nil else { return }
        let timer = Timer(
            timeInterval: Layout.screenFollowInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.followMouseScreenIfNeeded()
            }
        }
        screenFollowTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopScreenFollowTimer() {
        screenFollowTimer?.invalidate()
        screenFollowTimer = nil
    }

    private static func displayID(for screen: NSScreen?) -> CGDirectDisplayID? {
        guard let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }

    private static func screenContainingMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouseLocation) }
    }

    private func captureMouseScreenAsPreferredDisplay() {
        guard let screen = Self.screenContainingMouse(),
              let displayID = Self.displayID(for: screen) else {
            return
        }
        preferredDisplayID = displayID
    }

    private func closePanelIfNeededForOutsideClick() {
        guard viewModel.isOpen, let panel else { return }
        guard !settings.assistantCompactSidebarPinned else { return }
        let mouseLocation = NSEvent.mouseLocation
        guard !panel.frame.contains(mouseLocation) else { return }
        closePanel()
    }

    private func followMouseScreenIfNeeded() {
        guard isEnabled, !viewModel.isOpen,
              let screen = Self.screenContainingMouse(),
              shouldTransferCollapsedHandle(to: screen),
              let targetDisplayID = Self.displayID(for: screen),
              preferredDisplayID != targetDisplayID else {
            return
        }
        preferredDisplayID = targetDisplayID
        ensurePanelVisible(animated: true)
    }

    private func shouldTransferCollapsedHandle(to screen: NSScreen) -> Bool {
        let mouseLocation = NSEvent.mouseLocation
        let visibleFrame = screen.visibleFrame

        guard visibleFrame.contains(mouseLocation) else {
            return false
        }

        switch settings.assistantCompactSidebarEdge {
        case .left:
            return mouseLocation.x <= visibleFrame.minX + Layout.screenSwitchActivationWidth
        case .right:
            return mouseLocation.x >= visibleFrame.maxX - Layout.screenSwitchActivationWidth
        }
    }
}

private struct AssistantCompactSidebarRootView: View {
    private let handleWidth: CGFloat = 18
    let assistant: AssistantStore
    @ObservedObject var settings: SettingsStore
    @ObservedObject var viewModel: AssistantCompactSidebarManager.ViewModel
    let onToggleOpen: () -> Void
    let onMoveEdge: (AssistantCompactSidebarEdge) -> Void
    let onOpenFullAssistant: () -> Void

    private var isLeftEdge: Bool {
        settings.assistantCompactSidebarEdge == .left
    }

    var body: some View {
        HStack(spacing: 0) {
            if isLeftEdge {
                handle
                contentHost
            } else {
                contentHost
                handle
            }
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: isLeftEdge ? .leading : .trailing
        )
        .clipped()
        .background(Color.clear)
    }

    private var contentHost: some View {
        content
            .frame(width: viewModel.isOpen ? max(viewModel.contentWidth, 0) : 0)
            .frame(maxHeight: .infinity)
            .clipped()
            .opacity(viewModel.isOpen ? 1 : 0)
            .allowsHitTesting(viewModel.isOpen)
            .accessibilityHidden(!viewModel.isOpen)
            .zIndex(0)
    }

    private var handle: some View {
        Button(action: onToggleOpen) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(handleBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(handleStroke, lineWidth: 1)
                )
                .overlay {
                    Image(systemName: handleSymbol)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(handleTint)
                }
                .frame(width: 18, height: 84)
                .shadow(color: handleGlow, radius: 14, x: 0, y: 0)
        }
        .buttonStyle(.plain)
        .frame(width: handleWidth)
        .frame(maxHeight: .infinity, alignment: .center)
        .zIndex(2)
        .help(viewModel.isOpen ? "Close sidebar assistant" : "Open sidebar assistant")
        .contextMenu {
            Button(settings.assistantCompactSidebarPinned ? "Unpin Sidebar" : "Pin Sidebar") {
                settings.assistantCompactSidebarPinned.toggle()
            }

            Divider()

            Button("Move to Left") {
                onMoveEdge(.left)
            }
            .disabled(isLeftEdge)

            Button("Move to Right") {
                onMoveEdge(.right)
            }
            .disabled(!isLeftEdge)

            Divider()

            Button("Open Full Assistant") {
                onOpenFullAssistant()
            }
        }
    }

    private var content: some View {
        let panelShape = RoundedRectangle(cornerRadius: 28, style: .continuous)

        return AssistantWindowView(
            assistant: assistant,
            presentationStyle: .compactSidebar
        )
        .environmentObject(settings)
        .clipShape(panelShape)
        .overlay(
            panelShape
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .compositingGroup()
        .shadow(color: Color.black.opacity(0.35), radius: 28, x: 0, y: 14)
    }

    private var handleSymbol: String {
        switch (isLeftEdge, viewModel.isOpen) {
        case (true, true):
            return "chevron.left"
        case (true, false):
            return "chevron.right"
        case (false, true):
            return "chevron.right"
        case (false, false):
            return "chevron.left"
        }
    }

    private var handleTint: Color {
        switch viewModel.hudState.phase {
        case .idle:
            return AppVisualTheme.foreground(0.92)
        case .listening:
            return .green.opacity(0.88)
        case .thinking, .acting, .streaming:
            return AppVisualTheme.accentTint
        case .waitingForPermission:
            return .orange.opacity(0.92)
        case .success:
            return .mint.opacity(0.9)
        case .failed:
            return .red.opacity(0.9)
        }
    }

    private var handleBackground: LinearGradient {
        LinearGradient(
            colors: [
                AppVisualTheme.sidebarTint.opacity(viewModel.isOpen ? 0.82 : 0.76),
                AppVisualTheme.accentTint.opacity(viewModel.isOpen ? 0.22 : 0.18),
                AppVisualTheme.accentTint.opacity(viewModel.isOpen ? 0.52 : 0.42)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var handleStroke: Color {
        AppVisualTheme.accentTint.opacity(viewModel.isOpen ? 0.28 : 0.22)
    }

    private var handleGlow: Color {
        AppVisualTheme.accentTint.opacity(viewModel.isOpen ? 0.24 : 0.18)
    }
}
