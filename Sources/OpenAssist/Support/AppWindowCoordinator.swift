import AppKit
import SwiftUI

enum AppWindowFrameFitter {
    static func adaptedMinimumSize(
        preferredMinimumSize: NSSize,
        visibleFrame: NSRect?,
        fallbackMinimumSize: NSSize = NSSize(width: 420, height: 320),
        screenPadding: NSSize = NSSize(width: 24, height: 24)
    ) -> NSSize {
        guard let visibleFrame else {
            return preferredMinimumSize
        }

        let availableWidth = max(
            fallbackMinimumSize.width,
            visibleFrame.width - screenPadding.width
        )
        let availableHeight = max(
            fallbackMinimumSize.height,
            visibleFrame.height - screenPadding.height
        )

        return NSSize(
            width: min(preferredMinimumSize.width, availableWidth),
            height: min(preferredMinimumSize.height, availableHeight)
        )
    }

    static func centeredFrame(size: NSSize, in visibleFrame: NSRect) -> NSRect {
        NSRect(
            x: visibleFrame.midX - (size.width / 2),
            y: visibleFrame.midY - (size.height / 2),
            width: size.width,
            height: size.height
        )
    }

    static func fittedFrame(
        _ frame: NSRect,
        within visibleFrame: NSRect,
        minimumSize: NSSize
    ) -> NSRect {
        let fittedSize = NSSize(
            width: min(max(frame.width, minimumSize.width), visibleFrame.width),
            height: min(max(frame.height, minimumSize.height), visibleFrame.height)
        )

        let needsRecentering =
            abs(fittedSize.width - frame.width) > 0.5
            || abs(fittedSize.height - frame.height) > 0.5
            || !visibleFrame.intersects(frame)

        let unclampedOrigin = needsRecentering
            ? centeredFrame(size: fittedSize, in: visibleFrame).origin
            : frame.origin

        let minX = visibleFrame.minX
        let maxX = visibleFrame.maxX - fittedSize.width
        let minY = visibleFrame.minY
        let maxY = visibleFrame.maxY - fittedSize.height

        let clampedOrigin = NSPoint(
            x: min(max(unclampedOrigin.x, minX), maxX),
            y: min(max(unclampedOrigin.y, minY), maxY)
        )

        return NSRect(origin: clampedOrigin, size: fittedSize)
    }
}

private final class AppHostWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        if shouldZoomOnDoubleClick(for: event) {
            zoom(nil)
            return
        }

        super.sendEvent(event)
    }

    private func shouldZoomOnDoubleClick(for event: NSEvent) -> Bool {
        guard event.type == .leftMouseUp,
              event.clickCount == 2,
              styleMask.contains(.resizable) else {
            return false
        }

        let location = event.locationInWindow
        guard location.y >= contentLayoutRect.maxY else {
            return false
        }

        let standardButtons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for buttonType in standardButtons {
            if let button = standardWindowButton(buttonType), button.frame.contains(location) {
                return false
            }
        }

        return true
    }
}

@MainActor
final class AppWindowCoordinator: NSObject, NSWindowDelegate {
    private let settingsDefaultSize = NSSize(width: 900, height: 680)
    private let settingsMinimumSize = NSSize(width: 820, height: 560)
    private let aiStudioDefaultSize = NSSize(width: 1120, height: 760)
    private let aiStudioMinimumSize = NSSize(width: 1000, height: 620)
    private let assistantDefaultSize = NSSize(width: 1180, height: 760)
    private let assistantMinimumSize = NSSize(width: 980, height: 620)
    private let historyDefaultSize = NSSize(width: 620, height: 500)
    private let historyMinimumSize = NSSize(width: 520, height: 360)
    private let onboardingDefaultSize = NSSize(width: 700, height: 620)
    private let onboardingMinimumSize = NSSize(width: 620, height: 540)

    private let settings: SettingsStore
    private let transcriptHistory: TranscriptHistoryStore
    private let onStatusUpdate: (DictationUIStatus) -> Void
    private let onInsertText: (String) -> Void
    var onAssistantWindowVisibilityChanged: ((Bool) -> Void)?

    private var settingsWindowController: NSWindowController?
    private var aiStudioWindowController: NSWindowController?
    private var assistantWindowController: NSWindowController?
    private var assistantHostingController: NSHostingController<AnyView>?
    private var historyWindowController: NSWindowController?
    private var onboardingWindowController: NSWindowController?
    private var historyTargetApplication: NSRunningApplication?
    private var onboardingCompletion: (() -> Void)?
    private var activationPolicyObservers: [NSObjectProtocol] = []
    private var pendingAssistantWindowFitWorkItem: DispatchWorkItem?
    private var assistantWindowNeedsPostMoveFit = false

    private let assistantWindowFitDebounceDelay: TimeInterval = 0.18

    private var standardWindowCollectionBehavior: NSWindow.CollectionBehavior {
        [.moveToActiveSpace, .fullScreenPrimary]
    }

    var assistantWindowScreen: NSScreen? {
        assistantWindowController?.window?.screen
    }

    init(
        settings: SettingsStore,
        transcriptHistory: TranscriptHistoryStore,
        onStatusUpdate: @escaping (DictationUIStatus) -> Void,
        onInsertText: @escaping (String) -> Void
    ) {
        self.settings = settings
        self.transcriptHistory = transcriptHistory
        self.onStatusUpdate = onStatusUpdate
        self.onInsertText = onInsertText
        super.init()
        installActivationPolicyObservers()
        syncActivationPolicyToCurrentWindows()
    }

    deinit {
        let center = NotificationCenter.default
        for observer in activationPolicyObservers {
            center.removeObserver(observer)
        }
    }

    func openSettingsWindow(route: SettingsRoute? = nil) {
        onStatusUpdate(.openingSettings)
        requestDockActivation()

        let hostingController = NSHostingController(rootView: SettingsView(initialRoute: route).environmentObject(settings))
        if settingsWindowController == nil {
            let window = AppHostWindow(
                contentRect: NSRect(origin: .zero, size: settingsDefaultSize),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )

            window.title = "Open Assist Settings"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isOpaque = false
            window.backgroundColor = AppVisualTheme.windowBackdropNSColor
            window.toolbarStyle = .unifiedCompact
            window.isMovableByWindowBackground = false
            window.contentViewController = hostingController
            window.hidesOnDeactivate = false
            window.collectionBehavior = standardWindowCollectionBehavior
            window.isReleasedWhenClosed = false
            window.minSize = settingsMinimumSize
            centerWindowOnActiveScreen(window)
            window.delegate = self

            settingsWindowController = NSWindowController(window: window)
        } else {
            settingsWindowController?.contentViewController = hostingController
        }

        guard let window = settingsWindowController?.window else {
            onStatusUpdate(.message("Could not open settings"))
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        settingsWindowController?.showWindow(nil)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        if window.frame.width < settingsMinimumSize.width || window.frame.height < settingsMinimumSize.height {
            window.setContentSize(settingsDefaultSize)
        }
        centerWindowOnActiveScreen(window)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        aiStudioWindowController?.close()
        onStatusUpdate(.ready)
    }

    func openPermissionOnboardingWindow(onComplete: @escaping () -> Void) {
        onboardingCompletion = onComplete
        requestDockActivation()

        if onboardingWindowController == nil {
            let onboardingView = PermissionOnboardingView(onComplete: { [weak self] in
                guard let self else { return }
                self.onboardingCompletion?()
            })
            .environmentObject(settings)

            let hostingController = NSHostingController(rootView: onboardingView)
            let window = AppHostWindow(
                contentRect: NSRect(origin: .zero, size: onboardingDefaultSize),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )

            window.title = "Open Assist Permission Setup"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isOpaque = false
            window.backgroundColor = AppVisualTheme.windowBackdropNSColor
            window.toolbarStyle = .unifiedCompact
            window.isMovableByWindowBackground = false
            window.contentViewController = hostingController
            window.hidesOnDeactivate = false
            window.collectionBehavior = standardWindowCollectionBehavior
            window.isReleasedWhenClosed = false
            window.minSize = onboardingMinimumSize
            centerWindowOnActiveScreen(window)
            window.delegate = self

            onboardingWindowController = NSWindowController(window: window)
        }

        guard let window = onboardingWindowController?.window else {
            onStatusUpdate(.message("Could not open permission setup"))
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        onboardingWindowController?.showWindow(nil)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        if window.frame.width < onboardingMinimumSize.width || window.frame.height < onboardingMinimumSize.height {
            window.setContentSize(onboardingDefaultSize)
        }
        centerWindowOnActiveScreen(window)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
    }

    func openAIMemoryStudioWindow() {
        let pendingPage = AIStudioNavigationState.shared.pendingRequest?.pageRawValue ?? "models"
        let route: SettingsRoute
        if pendingPage.lowercased().hasPrefix("assistant") {
            route = SettingsRoute(section: .assistant, subsection: .assistantSetup)
        } else {
            route = SettingsRoute(section: .modelsConnections, subsection: .modelsConnections)
        }
        openSettingsWindow(route: route)
    }

    func openAssistantWindow<Content: View>(rootView: Content) {
        onStatusUpdate(.openingSettings)
        requestDockActivation()

        if assistantWindowController == nil {
            let hostingController = NSHostingController(rootView: AnyView(rootView))
            // Prevent the hosting controller from resizing the window when
            // SwiftUI content changes (e.g. mode switch, agent stop).
            hostingController.sizingOptions = []
            assistantHostingController = hostingController

            let window = AppHostWindow(
                contentRect: NSRect(origin: .zero, size: assistantDefaultSize),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Open Assist Assistant"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isOpaque = false
            window.backgroundColor = AppVisualTheme.windowBackdropNSColor
            let toolbar = NSToolbar(identifier: "assistantToolbar")
            toolbar.showsBaselineSeparator = false
            window.toolbar = toolbar
            window.toolbarStyle = .unifiedCompact
            window.isMovableByWindowBackground = false
            window.contentViewController = hostingController
            window.hidesOnDeactivate = false
            window.collectionBehavior = standardWindowCollectionBehavior
            window.isReleasedWhenClosed = false
            window.minSize = assistantMinimumSize
            centerWindowOnActiveScreen(window)
            window.delegate = self

            assistantWindowController = NSWindowController(window: window)
        }
        // Do NOT replace rootView or contentViewController when the window
        // already exists — the SwiftUI view observes the same store, so
        // rebuilding the hierarchy is unnecessary and causes layout jumps.

        guard let window = assistantWindowController?.window else {
            onStatusUpdate(.message("Could not open assistant"))
            return
        }

        let wasVisible = window.isVisible
        NSApp.activate(ignoringOtherApps: true)
        assistantWindowController?.showWindow(nil)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        ensureReadableAssistantWindowFrame(window, wasVisible: wasVisible)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        onStatusUpdate(.ready)
        onAssistantWindowVisibilityChanged?(true)
    }

    func closePermissionOnboardingWindow() {
        onboardingWindowController?.close()
        onboardingWindowController = nil
    }

    func closeAssistantWindow() {
        assistantWindowController?.close()
        assistantWindowController = nil
        assistantHostingController = nil
        setActivationPolicyForOpenWindows()
        onAssistantWindowVisibilityChanged?(false)
    }

    func openHistoryWindow() {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            historyTargetApplication = frontmost
        }
        requestDockActivation()

        if historyWindowController == nil {
            let historyView = TranscriptHistoryView(
                onCopy: { [weak self] text in
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(text, forType: .string)
                    self?.onStatusUpdate(.copiedFromHistory)
                },
                onReinsert: { [weak self] text in
                    self?.reinsertFromHistory(text)
                }
            )
            .environmentObject(transcriptHistory)

            let hostingController = NSHostingController(rootView: historyView)
            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: historyDefaultSize),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.title = "Transcript History"
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isOpaque = false
            panel.backgroundColor = AppVisualTheme.windowBackdropNSColor
            panel.isMovableByWindowBackground = false
            panel.toolbarStyle = .unifiedCompact
            panel.contentViewController = hostingController
            panel.isFloatingPanel = false
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
            panel.minSize = historyMinimumSize
            panel.center()
            panel.delegate = self

            historyWindowController = NSWindowController(window: panel)
        }

        guard let window = historyWindowController?.window else { return }
        NSApp.activate(ignoringOtherApps: true)
        historyWindowController?.showWindow(nil)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        if window.frame.width < historyMinimumSize.width || window.frame.height < historyMinimumSize.height {
            window.setContentSize(historyDefaultSize)
            window.center()
        }
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
    }

    func closeAllWindows() {
        cancelPendingAssistantWindowFit()
        onboardingWindowController?.close()
        onboardingWindowController = nil
        settingsWindowController?.close()
        settingsWindowController = nil
        aiStudioWindowController?.close()
        aiStudioWindowController = nil
        assistantWindowController?.close()
        assistantWindowController = nil
        assistantHostingController = nil
        historyWindowController?.close()
        historyWindowController = nil
        setActivationPolicyForOpenWindows()
        onAssistantWindowVisibilityChanged?(false)
    }

    func windowWillClose(_ notification: Notification) {
        if let closingWindow = notification.object as? NSWindow {
            if closingWindow === settingsWindowController?.window {
                settingsWindowController = nil
            } else if closingWindow === aiStudioWindowController?.window {
                aiStudioWindowController = nil
            } else if closingWindow === assistantWindowController?.window {
                cancelPendingAssistantWindowFit()
                assistantWindowController = nil
                assistantHostingController = nil
                onAssistantWindowVisibilityChanged?(false)
            } else if closingWindow === historyWindowController?.window {
                historyWindowController = nil
            } else if closingWindow === onboardingWindowController?.window {
                onboardingWindowController = nil
            }
        }
        setActivationPolicyForOpenWindows()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === assistantWindowController?.window else {
            return
        }

        assistantWindowNeedsPostMoveFit = true
        scheduleAssistantWindowFit(window)
    }

    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === assistantWindowController?.window,
              assistantWindowNeedsPostMoveFit else {
            return
        }

        scheduleAssistantWindowFit(window)
    }

    private func reinsertFromHistory(_ text: String) {
        guard !text.isEmpty else { return }

        if let target = historyTargetApplication, !target.isTerminated {
            _ = target.activate(options: [.activateIgnoringOtherApps])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
                self?.onInsertText(text)
            }
        } else {
            onInsertText(text)
        }
    }

    private func ensureReadableAssistantWindowFrame(_ window: NSWindow, wasVisible: Bool) {
        // When the window is already visible the user may have intentionally
        // resized it — respect that choice and skip size enforcement.
        guard !wasVisible else { return }

        fitAssistantWindowToVisibleScreen(window)
    }

    private func targetAssistantWindowSize(for visibleFrame: NSRect?) -> NSSize {
        guard let visibleFrame else { return assistantDefaultSize }

        let horizontalPadding: CGFloat = 48
        let verticalPadding: CGFloat = 56
        let adaptedMinimumSize = AppWindowFrameFitter.adaptedMinimumSize(
            preferredMinimumSize: assistantMinimumSize,
            visibleFrame: visibleFrame
        )
        let maxWidth = max(adaptedMinimumSize.width, visibleFrame.width - horizontalPadding)
        let maxHeight = max(adaptedMinimumSize.height, visibleFrame.height - verticalPadding)

        return NSSize(
            width: min(assistantDefaultSize.width, maxWidth),
            height: min(assistantDefaultSize.height, maxHeight)
        )
    }

    private func fitAssistantWindowToVisibleScreen(_ window: NSWindow) {
        guard let visibleFrame = preferredVisibleFrame(for: window) else {
            return
        }

        let adaptedMinimumSize = AppWindowFrameFitter.adaptedMinimumSize(
            preferredMinimumSize: assistantMinimumSize,
            visibleFrame: visibleFrame
        )
        if window.minSize != adaptedMinimumSize {
            window.minSize = adaptedMinimumSize
        }

        let fittedFrame = AppWindowFrameFitter.fittedFrame(
            window.frame,
            within: visibleFrame,
            minimumSize: adaptedMinimumSize
        )
        guard fittedFrame.integral != window.frame.integral else {
            return
        }

        window.setFrame(fittedFrame, display: false)
    }

    private func scheduleAssistantWindowFit(_ window: NSWindow) {
        pendingAssistantWindowFitWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self, weak window] in
            guard let self, let window,
                  window === self.assistantWindowController?.window else {
                return
            }

            if (NSEvent.pressedMouseButtons & 1) == 1 {
                self.scheduleAssistantWindowFit(window)
                return
            }

            self.pendingAssistantWindowFitWorkItem = nil
            self.assistantWindowNeedsPostMoveFit = false
            self.fitAssistantWindowToVisibleScreen(window)
        }

        pendingAssistantWindowFitWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + assistantWindowFitDebounceDelay,
            execute: workItem
        )
    }

    private func cancelPendingAssistantWindowFit() {
        pendingAssistantWindowFitWorkItem?.cancel()
        pendingAssistantWindowFitWorkItem = nil
        assistantWindowNeedsPostMoveFit = false
    }

    private func preferredVisibleFrame(for window: NSWindow) -> NSRect? {
        if let screen = window.screen {
            return screen.visibleFrame
        }
        if let screen = Self.screen(containing: window.frame) {
            return screen.visibleFrame
        }
        return (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
    }

    private func centerWindowOnActiveScreen(_ window: NSWindow) {
        guard let visibleFrame = preferredVisibleFrame(for: window) else {
            window.center()
            return
        }

        let frame = AppWindowFrameFitter.centeredFrame(size: window.frame.size, in: visibleFrame)
        window.setFrameOrigin(frame.origin)
    }

    private static func screen(containing frame: NSRect) -> NSScreen? {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first(where: { $0.frame.contains(center) })
            ?? NSScreen.screens.first(where: { $0.frame.intersects(frame) })
    }

    private func requestDockActivation() {
        NSApp.setActivationPolicy(.regular)
    }

    private func setActivationPolicyForOpenWindows() {
        syncActivationPolicyToCurrentWindows()
    }

    func syncActivationPolicyToCurrentWindows() {
        NSApp.setActivationPolicy(hasVisibleWorkWindow ? .regular : .accessory)
    }

    private var hasVisibleWorkWindow: Bool {
        NSApp.windows.contains(where: shouldCountForRegularActivation(_:))
    }

    private func installActivationPolicyObservers() {
        let center = NotificationCenter.default
        let observedNames: [Notification.Name] = [
            NSWindow.didBecomeMainNotification,
            NSWindow.didResignMainNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.willCloseNotification
        ]

        activationPolicyObservers = observedNames.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.syncActivationPolicyToCurrentWindows()
                }
            }
        }
    }

    private func shouldCountForRegularActivation(_ window: NSWindow) -> Bool {
        guard !window.isMiniaturized else {
            return false
        }

        let styleMask = window.styleMask
        guard styleMask.contains(.titled) else {
            return false
        }
        guard !styleMask.contains(.nonactivatingPanel) else {
            return false
        }

        let isActuallyVisible = window.isVisible || window.occlusionState.contains(.visible)
        guard isActuallyVisible else {
            return false
        }

        if let panel = window as? NSPanel,
           panel.isFloatingPanel,
           !styleMask.contains(.miniaturizable),
           !styleMask.contains(.resizable) {
            return false
        }

        return true
    }
}
