import AppKit
import SwiftUI

@MainActor
enum PromptRewritePreviewChoice {
    case useSuggested
    case editThenInsert
    case insertOriginal
    case rejectSuggestion
}

enum PromptRewriteBubbleEdge {
    case top
    case bottom
}

struct PromptRewriteInsertionHUDContext: Equatable {
    let sessionID: UUID
    let anchorRect: NSRect
    let screenNumber: UInt32?
    let screenName: String
    let targetProcessIdentifier: pid_t?
}

struct PromptRewriteLoadingDisplayState: Equatable {
    let transcription: String
    let currentStep: String
    let aiSuggestionsEnabled: Bool
    let aiGenerationSummary: String
    let aiRuntimeSummary: String?
    let partialPreviewText: String?
    let isStreamingPreviewActive: Bool

    static let placeholder = PromptRewriteLoadingDisplayState(
        transcription: "",
        currentStep: "Preparing request",
        aiSuggestionsEnabled: false,
        aiGenerationSummary: "AI suggestions are currently disabled.",
        aiRuntimeSummary: nil,
        partialPreviewText: nil,
        isStreamingPreviewActive: false
    )
}

@MainActor
final class PromptRewriteLoadingStateModel: ObservableObject {
    @Published var displayState: PromptRewriteLoadingDisplayState = .placeholder

    func update(with state: PromptRewriteLoadingDisplayState) {
        guard displayState != state else { return }
        displayState = state
    }
}

private struct PromptRewriteHUDPlacement {
    let frame: NSRect
    let bubbleEdge: PromptRewriteBubbleEdge
    let bubbleOffsetX: CGFloat
}

private struct PromptRewriteHUDSessionKey: Hashable {
    let sessionID: UUID
    let screenNumber: UInt32?
    let processIdentifier: Int?
}

enum PromptRewriteHUDLayout {
    static let panelWidth: CGFloat = 500
    static let minPanelHeight: CGFloat = 84
    static let maxPanelHeight: CGFloat = 166
    static let screenMargin: CGFloat = 8
    static let anchorGap: CGFloat = 14
    static let cornerRadius: CGFloat = 26
    static let loadingSize = NSSize(width: 420, height: 154)
    static let loadingOffsetY: CGFloat = 16
}

private final class PromptRewriteHUDKeyEventSuppressor {
    typealias KeyDownHandler = (UInt16) -> Void

    private static let blockedModifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]

    private let suppressedKeyCodes: Set<UInt16>
    private let onSuppressedKeyDown: KeyDownHandler
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(suppressedKeyCodes: Set<UInt16>, onSuppressedKeyDown: @escaping KeyDownHandler) {
        self.suppressedKeyCodes = suppressedKeyCodes
        self.onSuppressedKeyDown = onSuppressedKeyDown
    }

    deinit {
        stop()
    }

    func start() {
        stop()

        let eventsOfInterest = CGEventMask(1) << CGEventType.keyDown.rawValue
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let suppressor = Unmanaged<PromptRewriteHUDKeyEventSuppressor>.fromOpaque(userInfo).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = suppressor.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            guard type == .keyDown else {
                return Unmanaged.passUnretained(event)
            }

            guard let keyCode = suppressor.suppressedKeyCode(for: event) else {
                return Unmanaged.passUnretained(event)
            }

            suppressor.notifySuppressedKeyDown(keyCode)
            return nil
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventsOfInterest,
            callback: callback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else {
            CrashReporter.logInfo("HUD key suppressor: failed to create event tap")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source

        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }

        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }

        if let tap = eventTap {
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
    }

    private func suppressedKeyCode(for event: CGEvent) -> UInt16? {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard suppressedKeyCodes.contains(keyCode) else { return nil }
        if !event.flags.intersection(Self.blockedModifiers).isEmpty {
            return nil
        }
        return keyCode
    }

    private func notifySuppressedKeyDown(_ keyCode: UInt16) {
        DispatchQueue.main.async {
            self.onSuppressedKeyDown(keyCode)
        }
    }
}

@MainActor
final class PromptRewriteHUDManager {
    static let shared = PromptRewriteHUDManager()

    private enum HUDKeyCodes {
        static let escape: UInt16 = 53
        static let returnKey: UInt16 = 36
        static let keypadEnter: UInt16 = 76
    }

    private struct PendingSuggestion: Identifiable {
        let id: UUID
        let originalText: String
        let suggestion: PromptRewriteSuggestion
        let continuation: CheckedContinuation<PromptRewritePreviewChoice, Never>
    }

    @MainActor
    private final class PromptRewriteHUDSession {
        let key: PromptRewriteHUDSessionKey
        var insertionContext: PromptRewriteInsertionHUDContext
        let window: NSPanel
        var pendingSuggestions: [PendingSuggestion]
        var selectedSuggestionIndex: Int = 0
        var manualOffset: CGSize = .zero
        var dragBaseManualOffset: CGSize?

        init(key: PromptRewriteHUDSessionKey, insertionContext: PromptRewriteInsertionHUDContext, pendingSuggestions: [PendingSuggestion] = [], selectedSuggestionIndex: Int = 0) {
            self.key = key
            self.insertionContext = insertionContext
            self.window = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: PromptRewriteHUDLayout.panelWidth, height: 0),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            self.window.isFloatingPanel = true
            self.window.level = .floating
            self.window.backgroundColor = .clear
            self.window.isOpaque = false
            self.window.hasShadow = false
            self.window.hidesOnDeactivate = false
            self.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            self.window.contentView?.wantsLayer = true
            self.window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
            self.pendingSuggestions = pendingSuggestions
            self.selectedSuggestionIndex = selectedSuggestionIndex
        }

        deinit {
            let win = window
            Task { @MainActor [weak win] in
                win?.orderOut(nil)
                win?.contentViewController = nil
            }
        }
    }

    @MainActor
    private final class PromptRewriteLoadingSession {
        let key: PromptRewriteHUDSessionKey
        var insertionContext: PromptRewriteInsertionHUDContext
        let window: NSPanel
        let stateModel: PromptRewriteLoadingStateModel
        var manualOffset: CGSize = .zero
        var dragBaseManualOffset: CGSize?

        init(key: PromptRewriteHUDSessionKey, insertionContext: PromptRewriteInsertionHUDContext) {
            self.key = key
            self.insertionContext = insertionContext
            self.stateModel = PromptRewriteLoadingStateModel()
            self.window = NSPanel(
                contentRect: NSRect(origin: .zero, size: PromptRewriteHUDLayout.loadingSize),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            self.window.isFloatingPanel = true
            self.window.level = .floating
            self.window.backgroundColor = .clear
            self.window.isOpaque = false
            self.window.hasShadow = false
            self.window.hidesOnDeactivate = false
            self.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            self.window.contentView?.wantsLayer = true
            self.window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        }

        deinit {
            let win = window
            Task { @MainActor [weak win] in
                win?.orderOut(nil)
                win?.contentViewController = nil
            }
        }
    }

    private var sessions: [PromptRewriteHUDSessionKey: PromptRewriteHUDSession] = [:]
    private var loadingSessions: [PromptRewriteHUDSessionKey: PromptRewriteLoadingSession] = [:]
    private var activeSessionOrder: [PromptRewriteHUDSessionKey] = []
    private var activeLoadingSessionOrder: [PromptRewriteHUDSessionKey] = []
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var keyEventSuppressor: PromptRewriteHUDKeyEventSuppressor?
    private var loadingBypassRequests: Set<PromptRewriteHUDSessionKey> = []

    func showLoadingIndicator(
        insertionContext: PromptRewriteInsertionHUDContext,
        displayState: PromptRewriteLoadingDisplayState
    ) {
        installKeyMonitor()
        let key = sessionKey(for: insertionContext)
        loadingBypassRequests.remove(key)
        let session: PromptRewriteLoadingSession
        if let existing = loadingSessions[key] {
            session = existing
            session.insertionContext = insertionContext
        } else {
            session = PromptRewriteLoadingSession(key: key, insertionContext: insertionContext)
            loadingSessions[key] = session
        }
        touchLoadingSession(key)
        session.stateModel.update(with: displayState)

        let loadingView = makeLoadingView(for: key, stateModel: session.stateModel)
        if let hosting = session.window.contentViewController as? NSHostingController<PromptRewriteLoadingView> {
            hosting.rootView = loadingView
        } else {
            let hosting = NSHostingController(rootView: loadingView)
            session.window.contentViewController = hosting
            hosting.view.wantsLayer = true
            hosting.view.layer?.backgroundColor = NSColor.clear.cgColor
            hosting.view.frame = NSRect(origin: .zero, size: PromptRewriteHUDLayout.loadingSize)
        }

        let frame = loadingFrame(for: session.insertionContext, manualOffset: session.manualOffset)
        session.window.alphaValue = 1
        session.window.setFrame(frame, display: true)
        session.window.orderFrontRegardless()
    }

    func updateLoadingIndicator(
        insertionContext: PromptRewriteInsertionHUDContext,
        displayState: PromptRewriteLoadingDisplayState
    ) {
        let key = sessionKey(for: insertionContext)
        guard let session = loadingSessions[key] else { return }
        session.insertionContext = insertionContext
        session.stateModel.update(with: displayState)
    }

    func hideLoadingIndicator(insertionContext: PromptRewriteInsertionHUDContext) {
        let key = sessionKey(for: insertionContext)
        hideLoadingSession(for: key)
    }

    func clearLoadingBypassRequest(insertionContext: PromptRewriteInsertionHUDContext) {
        let key = sessionKey(for: insertionContext)
        loadingBypassRequests.remove(key)
    }

    func consumeLoadingBypassRequest(insertionContext: PromptRewriteInsertionHUDContext) -> Bool {
        let key = sessionKey(for: insertionContext)
        return loadingBypassRequests.remove(key) != nil
    }

    func requestLoadingBypass(insertionContext: PromptRewriteInsertionHUDContext) {
        requestLoadingBypass(for: sessionKey(for: insertionContext))
    }

    func captureCurrentInsertionContext(fallbackApp: NSRunningApplication?) -> PromptRewriteInsertionHUDContext {
        let rawAnchorRect = insertionAnchorRect()
        let validatedAnchorRect = usableAnchorRect(from: rawAnchorRect)
        let anchorRect = validatedAnchorRect ?? mouseAnchorRect()
        let usedInsertionAnchor = validatedAnchorRect != nil
        let fallbackScreen = screenContaining(point: NSPoint(x: anchorRect.midX, y: anchorRect.midY))
            ?? NSScreen.main
            ?? NSScreen.screens.first

        let screenName = fallbackScreen?.localizedName ?? "Current Screen"
        let screenNumber = screenNumber(for: fallbackScreen)
        let processIdentifier = captureTargetProcessID(fallbackApp: fallbackApp)
        CrashReporter.logInfo(
            "HUD anchor selected: \(anchorRect) source=\(usedInsertionAnchor ? "insertion" : "mouse-fallback")"
        )

        return PromptRewriteInsertionHUDContext(
            sessionID: UUID(),
            anchorRect: anchorRect,
            screenNumber: screenNumber,
            screenName: screenName,
            targetProcessIdentifier: processIdentifier
        )
    }

    func present(
        originalText: String,
        suggestion: PromptRewriteSuggestion,
        insertionContext: PromptRewriteInsertionHUDContext
    ) async -> PromptRewritePreviewChoice {
        let key = sessionKey(for: insertionContext)
        hideLoadingSession(for: key)
        let session: PromptRewriteHUDSession
        if let existing = sessions[key] {
            session = existing
            session.insertionContext = insertionContext
        } else {
            let newSession = PromptRewriteHUDSession(key: key, insertionContext: insertionContext)
            sessions[key] = newSession
            session = newSession
        }

        let result = await withCheckedContinuation { continuation in
            session.pendingSuggestions.append(
                PendingSuggestion(
                    id: UUID(),
                    originalText: originalText,
                    suggestion: suggestion,
                    continuation: continuation
                )
            )
            session.selectedSuggestionIndex = max(0, session.pendingSuggestions.count - 1)
            touchSession(key)
            render(session: session, animateIn: true)
        }

        return result
    }

    private func sessionKey(for insertionContext: PromptRewriteInsertionHUDContext) -> PromptRewriteHUDSessionKey {
        PromptRewriteHUDSessionKey(
            sessionID: insertionContext.sessionID,
            screenNumber: insertionContext.screenNumber,
            processIdentifier: insertionContext.targetProcessIdentifier.map { Int($0) }
        )
    }

    private func touchSession(_ key: PromptRewriteHUDSessionKey) {
        activeSessionOrder.removeAll(where: { $0 == key })
        activeSessionOrder.append(key)
    }

    private func touchLoadingSession(_ key: PromptRewriteHUDSessionKey) {
        activeLoadingSessionOrder.removeAll(where: { $0 == key })
        activeLoadingSessionOrder.append(key)
    }

    private func removeSessionFromOrder(_ key: PromptRewriteHUDSessionKey) {
        activeSessionOrder.removeAll(where: { $0 == key })
    }

    private func removeLoadingSessionFromOrder(_ key: PromptRewriteHUDSessionKey) {
        activeLoadingSessionOrder.removeAll(where: { $0 == key })
    }

    private func captureTargetProcessID(fallbackApp: NSRunningApplication?) -> pid_t? {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != selfPID {
            return frontmost.processIdentifier
        }
        if let fallback = fallbackApp,
           fallback.processIdentifier != selfPID,
           !fallback.isTerminated {
            return fallback.processIdentifier
        }
        return nil
    }

    private func render(session: PromptRewriteHUDSession, animateIn: Bool = false) {
        guard !session.pendingSuggestions.isEmpty else {
            removeSession(session.key)
            session.selectedSuggestionIndex = 0
            return
        }

        let boundedIndex = min(max(0, session.selectedSuggestionIndex), session.pendingSuggestions.count - 1)

        let pages = session.pendingSuggestions.map { pending in
            PromptRewriteDiscussionPage(
                id: pending.id,
                originalText: pending.originalText,
                suggestion: pending.suggestion
            )
        }

        let hosting = NSHostingController(
            rootView: makeView(
                pages: pages,
                selectedIndex: boundedIndex,
                bubbleEdge: .bottom,
                bubbleOffsetX: 0,
                sessionKey: session.key
            )
        )
        session.window.contentViewController = hosting
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = NSColor.clear.cgColor

        let targetSize = hosting.sizeThatFits(
            in: NSSize(width: PromptRewriteHUDLayout.panelWidth, height: PromptRewriteHUDLayout.maxPanelHeight)
        )
        let frame = NSRect(
            x: 0,
            y: 0,
            width: PromptRewriteHUDLayout.panelWidth,
            height: min(
                PromptRewriteHUDLayout.maxPanelHeight,
                max(PromptRewriteHUDLayout.minPanelHeight, targetSize.height)
            )
        )
        hosting.view.frame = frame

        let placement = resolvedPlacement(
            for: frame.size,
            context: session.insertionContext,
            manualOffset: session.manualOffset
        )
        hosting.rootView = makeView(
            pages: pages,
            selectedIndex: boundedIndex,
            bubbleEdge: placement.bubbleEdge,
            bubbleOffsetX: placement.bubbleOffsetX,
            sessionKey: session.key
        )
        session.window.orderFrontRegardless()
        show(window: session.window, at: placement.frame, bubbleEdge: placement.bubbleEdge, animated: animateIn || !session.window.isVisible)
    }

    private func makeView(
        pages: [PromptRewriteDiscussionPage],
        selectedIndex: Int,
        bubbleEdge: PromptRewriteBubbleEdge,
        bubbleOffsetX: CGFloat,
        sessionKey: PromptRewriteHUDSessionKey
    ) -> PromptRewriteHUDView {
        PromptRewriteHUDView(
            pages: pages,
            selectedIndex: selectedIndex,
            bubbleEdge: bubbleEdge,
            bubbleOffsetX: bubbleOffsetX,
            onSelectPage: { [weak self] newIndex in
                guard let self else { return }
                self.selectPage(newIndex, for: sessionKey)
            },
            onChoice: { [weak self] choice in
                guard let self else { return }
                self.finishSelected(sessionKey, with: choice)
            },
            onDragChanged: { [weak self] translation in
                guard let self else { return }
                self.updateDrag(translation, for: sessionKey, ended: false)
            },
            onDragEnded: { [weak self] translation in
                guard let self else { return }
                self.updateDrag(translation, for: sessionKey, ended: true)
            }
        )
    }

    private func selectPage(_ index: Int, for key: PromptRewriteHUDSessionKey) {
        guard let session = sessions[key], !session.pendingSuggestions.isEmpty else { return }
        session.selectedSuggestionIndex = min(max(0, index), session.pendingSuggestions.count - 1)
        touchSession(key)
        render(session: session)
    }

    private func finishSelected(_ sessionKey: PromptRewriteHUDSessionKey, with choice: PromptRewritePreviewChoice) {
        guard let session = sessions[sessionKey], !session.pendingSuggestions.isEmpty else { return }

        let index = min(max(0, session.selectedSuggestionIndex), session.pendingSuggestions.count - 1)
        let pending = session.pendingSuggestions.remove(at: index)

        guard !session.pendingSuggestions.isEmpty else {
            removeSession(sessionKey)
            pending.continuation.resume(returning: choice)
            return
        }

        session.selectedSuggestionIndex = min(index, session.pendingSuggestions.count - 1)
        pending.continuation.resume(returning: choice)
        render(session: session)
    }

    private func resolvedPlacement(for panelSize: NSSize, context: PromptRewriteInsertionHUDContext) -> PromptRewriteHUDPlacement {
        let anchorRect = context.anchorRect
        let anchorPoint = NSPoint(x: anchorRect.midX, y: anchorRect.midY)
        let screen = screenForDisplayNumber(context.screenNumber)
            ?? screenContaining(point: anchorPoint)
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        let pidString = context.targetProcessIdentifier.map { String($0) } ?? ""
        CrashReporter.logInfo("HUD placement: screen=\(context.screenName) anchorRect=\(anchorRect) appPID=\(pidString)")

        let preferredX = anchorRect.midX - (panelSize.width * 0.5)
        let minX = visibleFrame.minX + PromptRewriteHUDLayout.screenMargin
        let maxX = visibleFrame.maxX - panelSize.width - PromptRewriteHUDLayout.screenMargin
        let x = min(max(preferredX, minX), maxX)

        let gap = PromptRewriteHUDLayout.anchorGap
        let aboveY = anchorRect.maxY + gap
        let belowY = anchorRect.minY - panelSize.height - gap
        let minY = visibleFrame.minY + PromptRewriteHUDLayout.screenMargin
        let maxY = visibleFrame.maxY - panelSize.height - PromptRewriteHUDLayout.screenMargin

        let fitsAbove = aboveY >= minY && aboveY <= maxY
        let fitsBelow = belowY >= minY && belowY <= maxY

        let y: CGFloat
        let bubbleEdge: PromptRewriteBubbleEdge

        // Prefer placing above the anchor (higher Y in macOS coords).
        // If anchor is in the lower third of the screen, the "above" direction
        // gives more visible room. Fall back to below if it doesn't fit.
        if fitsAbove {
            y = aboveY
            bubbleEdge = .bottom
        } else if fitsBelow {
            y = belowY
            bubbleEdge = .top
        } else {
            // Neither fits perfectly — pick whichever has more room
            let aboveClamped = min(max(aboveY, minY), maxY)
            let belowClamped = min(max(belowY, minY), maxY)
            let aboveSpace = maxY - aboveClamped
            let belowSpace = belowClamped - minY
            if aboveSpace >= belowSpace {
                y = aboveClamped
                bubbleEdge = .bottom
            } else {
                y = belowClamped
                bubbleEdge = .top
            }
        }

        let maxBubbleOffset = (panelSize.width * 0.5) - 28
        let rawBubbleOffset = anchorRect.midX - (x + panelSize.width * 0.5)
        let bubbleOffsetX = min(max(rawBubbleOffset, -maxBubbleOffset), maxBubbleOffset)

        CrashReporter.logInfo("HUD placement: y=\(y) aboveY=\(aboveY) belowY=\(belowY) fitsAbove=\(fitsAbove) fitsBelow=\(fitsBelow) visibleFrame=\(visibleFrame)")
        return PromptRewriteHUDPlacement(
            frame: NSRect(x: x, y: y, width: panelSize.width, height: panelSize.height),
            bubbleEdge: bubbleEdge,
            bubbleOffsetX: bubbleOffsetX
        )
    }

    private func resolvedPlacement(
        for panelSize: NSSize,
        context: PromptRewriteInsertionHUDContext,
        manualOffset: CGSize
    ) -> PromptRewriteHUDPlacement {
        let basePlacement = resolvedPlacement(for: panelSize, context: context)
        guard manualOffset != .zero else { return basePlacement }

        let anchorRect = context.anchorRect
        let anchorPoint = NSPoint(x: anchorRect.midX, y: anchorRect.midY)
        let screen = screenForDisplayNumber(context.screenNumber)
            ?? screenContaining(point: anchorPoint)
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)

        let minX = visibleFrame.minX + PromptRewriteHUDLayout.screenMargin
        let maxX = visibleFrame.maxX - panelSize.width - PromptRewriteHUDLayout.screenMargin
        let minY = visibleFrame.minY + PromptRewriteHUDLayout.screenMargin
        let maxY = visibleFrame.maxY - panelSize.height - PromptRewriteHUDLayout.screenMargin

        let translatedX = basePlacement.frame.origin.x + manualOffset.width
        let translatedY = basePlacement.frame.origin.y + manualOffset.height
        let clampedX = min(max(translatedX, minX), maxX)
        let clampedY = min(max(translatedY, minY), maxY)
        let frame = NSRect(x: clampedX, y: clampedY, width: panelSize.width, height: panelSize.height)

        let bubbleEdge: PromptRewriteBubbleEdge = frame.midY >= anchorRect.midY ? .bottom : .top
        let maxBubbleOffset = (panelSize.width * 0.5) - 28
        let rawBubbleOffset = anchorRect.midX - frame.midX
        let bubbleOffsetX = min(max(rawBubbleOffset, -maxBubbleOffset), maxBubbleOffset)

        return PromptRewriteHUDPlacement(
            frame: frame,
            bubbleEdge: bubbleEdge,
            bubbleOffsetX: bubbleOffsetX
        )
    }

    private func updateDrag(
        _ translation: CGSize,
        for key: PromptRewriteHUDSessionKey,
        ended: Bool
    ) {
        guard let session = sessions[key], session.window.isVisible else { return }

        if session.dragBaseManualOffset == nil {
            session.dragBaseManualOffset = session.manualOffset
        }
        let baseOffset = session.dragBaseManualOffset ?? .zero
        // SwiftUI drag translation is in top-left coordinates. NSWindow uses bottom-left.
        let windowDelta = CGSize(width: translation.width, height: -translation.height)
        session.manualOffset = CGSize(
            width: baseOffset.width + windowDelta.width,
            height: baseOffset.height + windowDelta.height
        )

        let placement = resolvedPlacement(
            for: session.window.frame.size,
            context: session.insertionContext,
            manualOffset: session.manualOffset
        )
        session.window.setFrame(placement.frame, display: true)

        if ended {
            session.dragBaseManualOffset = nil
            render(session: session)
        }
    }

    private func makeLoadingView(
        for key: PromptRewriteHUDSessionKey,
        stateModel: PromptRewriteLoadingStateModel
    ) -> PromptRewriteLoadingView {
        PromptRewriteLoadingView(
            model: stateModel,
            onPause: { [weak self] in
                self?.requestLoadingBypass(for: key)
            },
            onDragChanged: { [weak self] translation in
                self?.updateLoadingDrag(translation, for: key, ended: false)
            },
            onDragEnded: { [weak self] translation in
                self?.updateLoadingDrag(translation, for: key, ended: true)
            }
        )
    }

    private func updateLoadingDrag(
        _ translation: CGSize,
        for key: PromptRewriteHUDSessionKey,
        ended: Bool
    ) {
        guard let session = loadingSessions[key], session.window.isVisible else { return }

        if session.dragBaseManualOffset == nil {
            session.dragBaseManualOffset = session.manualOffset
        }
        let baseOffset = session.dragBaseManualOffset ?? .zero
        let windowDelta = CGSize(width: translation.width, height: -translation.height)
        session.manualOffset = CGSize(
            width: baseOffset.width + windowDelta.width,
            height: baseOffset.height + windowDelta.height
        )

        let frame = loadingFrame(for: session.insertionContext, manualOffset: session.manualOffset)
        session.window.setFrame(frame, display: true)

        if ended {
            session.dragBaseManualOffset = nil
        }
    }

    private func requestLoadingBypass(for key: PromptRewriteHUDSessionKey) {
        loadingBypassRequests.insert(key)
        hideLoadingSession(for: key)
    }

    private func hideLoadingSession(for key: PromptRewriteHUDSessionKey) {
        guard let loading = loadingSessions.removeValue(forKey: key) else { return }
        loading.window.contentViewController = nil
        loading.window.orderOut(nil)
        loading.window.alphaValue = 1
        removeLoadingSessionFromOrder(key)
        maybeRemoveKeyMonitor()
    }

    private func loadingFrame(for context: PromptRewriteInsertionHUDContext, manualOffset: CGSize = .zero) -> NSRect {
        let size = PromptRewriteHUDLayout.loadingSize
        let anchorRect = context.anchorRect
        let anchorPoint = NSPoint(x: anchorRect.midX, y: anchorRect.midY)
        let screen = screenForDisplayNumber(context.screenNumber)
            ?? screenContaining(point: anchorPoint)
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)

        // Stack multiple loading HUDs vertically when they share similar anchor regions
        let sessionKey = sessionKey(for: context)
        let stackIndex = activeLoadingSessionOrder.firstIndex(of: sessionKey) ?? activeLoadingSessionOrder.count
        let stackOffset = CGFloat(stackIndex) * (size.height + 8)

        let proposedX = anchorRect.midX - (size.width * 0.5)
        let proposedY = anchorRect.midY + PromptRewriteHUDLayout.loadingOffsetY - stackOffset
        let minX = visibleFrame.minX + PromptRewriteHUDLayout.screenMargin
        let maxX = max(minX, visibleFrame.maxX - size.width - PromptRewriteHUDLayout.screenMargin)
        let minY = visibleFrame.minY + PromptRewriteHUDLayout.screenMargin
        let maxY = max(minY, visibleFrame.maxY - size.height - PromptRewriteHUDLayout.screenMargin)
        let baseX = min(max(proposedX, minX), maxX)
        let baseY = min(max(proposedY, minY), maxY)

        let translatedX = baseX + manualOffset.width
        let translatedY = baseY + manualOffset.height
        let clampedX = min(max(translatedX, minX), maxX)
        let clampedY = min(max(translatedY, minY), maxY)
        return NSRect(x: clampedX, y: clampedY, width: size.width, height: size.height)
    }

    private func show(window: NSPanel, at frame: NSRect, bubbleEdge: PromptRewriteBubbleEdge, animated: Bool) {
        installKeyMonitor()

        if !animated {
            window.alphaValue = 1
            window.setFrame(frame, display: true)
            if !window.isVisible {
                window.orderFrontRegardless()
            }
            return
        }

        let startYOffset: CGFloat = bubbleEdge == .bottom ? -10 : 10
        let startFrame = frame.offsetBy(dx: 0, dy: startYOffset)
        window.alphaValue = 0
        window.setFrame(startFrame, display: false)
        window.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.allowsImplicitAnimation = true
            window.animator().alphaValue = 1
            window.animator().setFrame(frame, display: true)
        }
    }

    private func removeSession(_ key: PromptRewriteHUDSessionKey) {
        guard let session = sessions.removeValue(forKey: key) else {
            return
        }
        loadingBypassRequests.remove(key)
        removeSessionFromOrder(key)
        hide(session: session)
        hideLoadingSession(for: key)
        maybeRemoveKeyMonitor()
    }

    private func hide(session: PromptRewriteHUDSession) {
        session.window.contentViewController = nil
        session.window.orderOut(nil)
        session.window.alphaValue = 1
        removeSessionFromOrder(session.key)
        maybeRemoveKeyMonitor()
    }

    private func maybeRemoveKeyMonitor() {
        if sessions.isEmpty && loadingSessions.isEmpty {
            removeKeyMonitor()
        }
    }

    private func installKeyMonitor() {
        if keyEventSuppressor == nil {
            keyEventSuppressor = PromptRewriteHUDKeyEventSuppressor(
                suppressedKeyCodes: [HUDKeyCodes.escape, HUDKeyCodes.returnKey, HUDKeyCodes.keypadEnter],
                onSuppressedKeyDown: { [weak self] keyCode in
                    _ = self?.handleHUDKeyCode(keyCode)
                }
            )
            keyEventSuppressor?.start()
        }

        guard globalKeyMonitor == nil, localKeyMonitor == nil else { return }

        // Use both monitors: global handles when another app is focused,
        // local handles cases where OpenAssist is active.
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            _ = self?.handleMonitoredKeyDown(event)
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let handled = self.handleMonitoredKeyDown(event)
            return handled ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let monitor = globalKeyMonitor {
            NSEvent.removeMonitor(monitor)
            globalKeyMonitor = nil
        }
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
        }
        keyEventSuppressor?.stop()
        keyEventSuppressor = nil
    }

    @discardableResult
    private func handleMonitoredKeyDown(_ event: NSEvent) -> Bool {
        // Ignore only explicit shortcut modifiers; do not gate on .function
        // because some keyboards set it for Esc/Enter variants.
        let blockingModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard blockingModifiers.isEmpty else { return false }

        return handleHUDKeyCode(event.keyCode)
    }

    @discardableResult
    private func handleHUDKeyCode(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case HUDKeyCodes.escape:
            return cancelMostRecentSession()
        case HUDKeyCodes.returnKey, HUDKeyCodes.keypadEnter:
            return acceptMostRecentSession()
        default:
            return false
        }
    }

    private func cancelMostRecentSession() -> Bool {
        if let key = latestVisibleSessionKey() {
            finishSelected(key, with: .insertOriginal)
            return true
        }
        guard let loadingKey = latestVisibleLoadingSessionKey() else { return false }
        requestLoadingBypass(for: loadingKey)
        return true
    }

    private func acceptMostRecentSession() -> Bool {
        guard let key = latestVisibleSessionKey() else { return false }
        finishSelected(key, with: .useSuggested)
        return true
    }

    private func latestVisibleSessionKey() -> PromptRewriteHUDSessionKey? {
        for key in activeSessionOrder.reversed() {
            guard let session = sessions[key], session.window.isVisible else { continue }
            return key
        }
        // Fallback for edge cases where visibility state lags while a session is still active.
        for key in activeSessionOrder.reversed() where sessions[key] != nil {
            return key
        }
        return nil
    }

    private func latestVisibleLoadingSessionKey() -> PromptRewriteHUDSessionKey? {
        for key in activeLoadingSessionOrder.reversed() {
            guard let session = loadingSessions[key], session.window.isVisible else { continue }
            return key
        }
        for key in activeLoadingSessionOrder.reversed() where loadingSessions[key] != nil {
            return key
        }
        return nil
    }

    private func screenForDisplayNumber(_ screenNumber: UInt32?) -> NSScreen? {
        guard let screenNumber else { return nil }
        return NSScreen.screens.first { screen in
            self.screenNumber(for: screen) == screenNumber
        }
    }

    private func screenNumber(for screen: NSScreen?) -> UInt32? {
        guard let screen else { return nil }
        return (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private func insertionAnchorRect() -> NSRect? {
        guard AXIsProcessTrusted() else { return nil }
        guard let focusedElement = focusedElement() else { return nil }

        if let editableAnchor = editableAnchorElement(startingAt: focusedElement) {
            let editableBounds = focusedElementBounds(for: editableAnchor)
            if let focusedBounds = editableBounds {
                return anchorRect(fromFocusedBounds: focusedBounds)
            }
            if let insertionBounds = insertionBounds(for: editableAnchor),
               isUsableInsertionBounds(insertionBounds, within: editableBounds) {
                return insertionBounds
            }
        }

        if let windowBounds = focusedWindowBounds(from: focusedElement) {
            return anchorRect(fromFocusedWindowBounds: windowBounds)
        }

        return nil
    }

    private func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        guard focusedResult == .success,
              let focusedRef,
              CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(focusedRef, to: AXUIElement.self)
    }

    private func insertionBounds(for focusedElement: AXUIElement) -> NSRect? {
        var selectedRangeRef: CFTypeRef?
        let selectedRangeResult = AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRangeRef
        )
        guard selectedRangeResult == .success,
              let selectedRangeRef,
              CFGetTypeID(selectedRangeRef) == AXValueGetTypeID() else {
            return nil
        }
        let selectedRangeAXValue = unsafeBitCast(selectedRangeRef, to: AXValue.self)
        guard AXValueGetType(selectedRangeAXValue) == .cfRange else {
            return nil
        }

        var boundsRef: CFTypeRef?
        let boundsResult = AXUIElementCopyParameterizedAttributeValue(
            focusedElement,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            selectedRangeAXValue,
            &boundsRef
        )
        guard boundsResult == .success,
              let boundsRef,
              CFGetTypeID(boundsRef) == AXValueGetTypeID() else {
            return nil
        }

        let boundsAXValue = unsafeBitCast(boundsRef, to: AXValue.self)
        guard AXValueGetType(boundsAXValue) == .cgRect else {
            return nil
        }

        var cgRect = CGRect.zero
        guard AXValueGetValue(boundsAXValue, .cgRect, &cgRect) else {
            return nil
        }

        if let normalized = normalizeAccessibilityRectToScreen(cgRect) {
            return normalized
        }
        return nil
    }

    private func isUsableInsertionBounds(_ bounds: NSRect, within focusedBounds: NSRect?) -> Bool {
        guard bounds.minX.isFinite,
              bounds.minY.isFinite,
              bounds.width.isFinite,
              bounds.height.isFinite else {
            return false
        }

        if bounds.width <= 0.5 && bounds.height <= 0.5 {
            return false
        }

        let point = NSPoint(x: bounds.midX, y: bounds.midY)
        guard screenContaining(point: point) != nil else {
            return false
        }

        if let focusedBounds {
            let expandedBounds = focusedBounds.insetBy(dx: -24, dy: -24)
            return expandedBounds.contains(point)
        }

        return true
    }

    private func focusedElementBounds(for focusedElement: AXUIElement) -> NSRect? {
        guard
            let position = pointAttribute(kAXPositionAttribute as CFString, on: focusedElement),
            let size = sizeAttribute(kAXSizeAttribute as CFString, on: focusedElement),
            size.width > 0,
            size.height > 0
        else {
            return nil
        }

        let candidate = CGRect(origin: position, size: size)
        return normalizeAccessibilityRectToScreen(candidate)
    }

    private func focusedWindowBounds(from focusedElement: AXUIElement) -> NSRect? {
        guard let windowElement = elementAttribute(kAXWindowAttribute as CFString, on: focusedElement) else {
            return nil
        }
        return focusedElementBounds(for: windowElement)
    }

    private func editableAnchorElement(startingAt focusedElement: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = focusedElement
        var depth = 0

        while let element = current, depth < 8 {
            if isEditableTextElement(element) {
                return element
            }
            current = elementAttribute(kAXParentAttribute as CFString, on: element)
            depth += 1
        }

        return nil
    }

    private func isEditableTextElement(_ element: AXUIElement) -> Bool {
        if boolAttribute("AXEditable" as CFString, on: element) == true {
            return true
        }

        let role = (stringAttribute(kAXRoleAttribute as CFString, on: element) ?? "").lowercased()
        if role == "axtextfield" || role == "axtextarea" || role == "axsearchfield" || role == "axcombobox" {
            return true
        }

        let hasTextRange = hasAttribute(kAXSelectedTextRangeAttribute as CFString, on: element)
        let hasTextValue = hasAttribute(kAXValueAttribute as CFString, on: element)
        return hasTextRange && hasTextValue
    }

    private func anchorRect(fromFocusedBounds bounds: NSRect) -> NSRect {
        // Center the HUD over the text area and place it just above the field.
        let anchorX = bounds.midX
        let anchorY = bounds.maxY
        return NSRect(x: anchorX, y: anchorY, width: 1, height: 1)
    }

    private func anchorRect(fromFocusedWindowBounds bounds: NSRect) -> NSRect {
        let anchorX = bounds.midX
        let anchorY = bounds.minY + min(180, max(68, bounds.height * 0.18))
        return NSRect(x: anchorX, y: anchorY, width: 1, height: 1)
    }

    private func elementAttribute(_ attribute: CFString, on element: AXUIElement) -> AXUIElement? {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &valueRef)
        guard result == .success,
              let valueRef,
              CFGetTypeID(valueRef) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(valueRef, to: AXUIElement.self)
    }

    private func stringAttribute(_ attribute: CFString, on element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &valueRef)
        guard result == .success else {
            return nil
        }
        return valueRef as? String
    }

    private func boolAttribute(_ attribute: CFString, on element: AXUIElement) -> Bool? {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &valueRef)
        guard result == .success, let number = valueRef as? NSNumber else {
            return nil
        }
        return number.boolValue
    }

    private func hasAttribute(_ attribute: CFString, on element: AXUIElement) -> Bool {
        var valueRef: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute, &valueRef) == .success
    }

    private func pointAttribute(_ attribute: CFString, on element: AXUIElement) -> CGPoint? {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &valueRef)
        guard result == .success,
              let valueRef,
              CFGetTypeID(valueRef) == AXValueGetTypeID() else {
            return nil
        }

        let value = unsafeBitCast(valueRef, to: AXValue.self)
        guard AXValueGetType(value) == .cgPoint else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return point
    }

    private func sizeAttribute(_ attribute: CFString, on element: AXUIElement) -> CGSize? {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &valueRef)
        guard result == .success,
              let valueRef,
              CFGetTypeID(valueRef) == AXValueGetTypeID() else {
            return nil
        }

        let value = unsafeBitCast(valueRef, to: AXValue.self)
        guard AXValueGetType(value) == .cgSize else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &size) else { return nil }
        return size
    }

    private func normalizeAccessibilityRectToScreen(_ rect: CGRect) -> NSRect? {
        // Accessibility API always uses top-left screen origin; NSScreen uses
        // bottom-left. Always flip Y to convert correctly, regardless of where
        // the mouse happens to be.
        if let flipped = normalizedFlippedRect(for: rect) {
            return flipped
        }
        // Fallback: use the raw rect if flipping lands off-screen (shouldn't
        // happen in practice, but keeps the path safe).
        let direct = NSRect(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
        let directPoint = NSPoint(x: direct.midX, y: direct.midY)
        return screenContaining(point: directPoint) != nil ? direct : nil
    }

    private func normalizedFlippedRect(for rect: CGRect) -> NSRect? {
        // AX coordinates use the primary display's top-left as origin.
        // The primary screen is always screens[0] and has frame.origin == .zero.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let flippedY = primaryHeight - rect.origin.y - rect.height
        let flipped = NSRect(x: rect.origin.x, y: flippedY, width: rect.width, height: rect.height)
        let flippedPoint = NSPoint(x: flipped.midX, y: flipped.midY)
        return screenContaining(point: flippedPoint) == nil ? nil : flipped
    }

    private func mouseAnchorRect() -> NSRect {
        let point = NSEvent.mouseLocation
        return NSRect(x: point.x, y: point.y, width: 1, height: 1)
    }

    private func usableAnchorRect(from candidate: NSRect?) -> NSRect? {
        guard var candidate else { return nil }
        guard candidate.minX.isFinite,
              candidate.minY.isFinite,
              candidate.width.isFinite,
              candidate.height.isFinite else {
            return nil
        }

        if candidate.width <= 0 {
            candidate.size.width = 1
        }
        if candidate.height <= 0 {
            candidate.size.height = 1
        }

        let point = NSPoint(x: candidate.midX, y: candidate.midY)
        guard screenContaining(point: point) != nil else {
            return nil
        }

        if abs(candidate.minX) < 0.5 && abs(candidate.minY) < 0.5 {
            return nil
        }

        return candidate
    }

    private func screenContaining(point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { screen in
            screen.frame.contains(point)
        }
    }
}
