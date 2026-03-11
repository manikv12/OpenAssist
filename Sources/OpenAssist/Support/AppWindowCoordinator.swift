import AppKit
import SwiftUI

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
    private let onboardingDefaultSize = NSSize(width: 620, height: 460)
    private let onboardingMinimumSize = NSSize(width: 560, height: 420)

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
    }

    func openSettingsWindow() {
        onStatusUpdate(.openingSettings)
        requestDockActivation()

        if settingsWindowController == nil {
            let hostingController = NSHostingController(rootView: SettingsView().environmentObject(settings))
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: settingsDefaultSize),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )

            window.title = "Open Assist Settings"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.toolbarStyle = .unifiedCompact
            window.isMovableByWindowBackground = false
            window.contentViewController = hostingController
            window.hidesOnDeactivate = false
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            window.minSize = settingsMinimumSize
            centerWindowOnActiveScreen(window)
            window.delegate = self

            settingsWindowController = NSWindowController(window: window)
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
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: onboardingDefaultSize),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )

            window.title = "Open Assist Permission Setup"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.toolbarStyle = .unifiedCompact
            window.isMovableByWindowBackground = false
            window.contentViewController = hostingController
            window.hidesOnDeactivate = false
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
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
        onStatusUpdate(.openingSettings)
        requestDockActivation()

        if aiStudioWindowController == nil {
            let hostingController = NSHostingController(rootView: AIMemoryStudioView().environmentObject(settings))
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: aiStudioDefaultSize),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "AI Studio"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.toolbarStyle = .unifiedCompact
            window.isMovableByWindowBackground = false
            window.contentViewController = hostingController
            window.hidesOnDeactivate = false
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            window.minSize = aiStudioMinimumSize
            centerWindowOnActiveScreen(window)
            window.delegate = self

            aiStudioWindowController = NSWindowController(window: window)
        }

        guard let window = aiStudioWindowController?.window else {
            onStatusUpdate(.message("Could not open AI Studio"))
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        aiStudioWindowController?.showWindow(nil)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        if window.frame.width < aiStudioMinimumSize.width || window.frame.height < aiStudioMinimumSize.height {
            window.setContentSize(aiStudioDefaultSize)
        }
        centerWindowOnActiveScreen(window)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        settingsWindowController?.close()
        onStatusUpdate(.ready)
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

            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: assistantDefaultSize),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Open Assist Assistant"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isOpaque = false
            window.backgroundColor = .clear
            let toolbar = NSToolbar(identifier: "assistantToolbar")
            toolbar.showsBaselineSeparator = false
            window.toolbar = toolbar
            window.toolbarStyle = .unifiedCompact
            window.isMovableByWindowBackground = true
            window.contentViewController = hostingController
            window.hidesOnDeactivate = false
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
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

        NSApp.activate(ignoringOtherApps: true)
        assistantWindowController?.showWindow(nil)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        // Only center when the window hasn't been shown yet.
        if !window.isVisible {
            if window.frame.width < assistantMinimumSize.width || window.frame.height < assistantMinimumSize.height {
                window.setContentSize(assistantDefaultSize)
            }
            centerWindowOnActiveScreen(window)
        }
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
            panel.backgroundColor = .clear
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

    private func centerWindowOnActiveScreen(_ window: NSWindow) {
        guard let visibleFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else {
            window.center()
            return
        }

        let frame = window.frame
        let origin = NSPoint(
            x: visibleFrame.midX - (frame.width / 2),
            y: visibleFrame.midY - (frame.height / 2)
        )
        window.setFrameOrigin(origin)
    }

    private func requestDockActivation() {
        NSApp.setActivationPolicy(.regular)
    }

    private func setActivationPolicyForOpenWindows() {
        let hasOpenWindows =
            settingsWindowController != nil ||
            aiStudioWindowController != nil ||
            assistantWindowController != nil ||
            historyWindowController != nil ||
            onboardingWindowController != nil
        NSApp.setActivationPolicy(hasOpenWindows ? .regular : .accessory)
    }
}
