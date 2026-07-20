import AppKit
import Foundation

@MainActor
final class PostInsertCorrectionMonitor {
    struct SessionResult {
        let originalText: String
        let correctedText: String
        let insertedText: String
    }

    var onCorrectionDetected: ((SessionResult) -> Void)?

    private struct Session {
        let insertedText: String
        let focusedElement: AXUIElement?
        let baselineText: String?
        let startedAt: Date
        var lastActivityAt: Date
        var sawEditIntent: Bool
    }

    private enum Constants {
        static let idleTimeout: TimeInterval = 3.5
        static let maxSessionDuration: TimeInterval = 15.0
        static let timerTick: TimeInterval = 0.25
        static let returnKeyCodes: Set<UInt16> = [36, 76]
        static let deleteKeyCodes: Set<UInt16> = [51, 117]
        static let navigationKeyCodes: Set<UInt16> = [123, 124, 125, 126, 115, 116, 119, 121]
    }

    private var globalKeyMonitor: Any?
    private var globalMouseMonitor: Any?
    private var sessionTimer: DispatchSourceTimer?
    private var session: Session?

    func startMonitoring(insertedText: String) {
        let trimmed = insertedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        stopMonitoring(commitSession: false)

        let focusedElement = focusedTextElement()
        let baselineText = focusedElement.flatMap(readTextValue(for:))
        let now = Date()
        session = Session(
            insertedText: trimmed,
            focusedElement: focusedElement,
            baselineText: baselineText,
            startedAt: now,
            lastActivityAt: now,
            sawEditIntent: false
        )

        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                self?.handleKeyDown(event)
            }
        }

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.markActivity()
            }
        }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Constants.timerTick, repeating: Constants.timerTick)
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        sessionTimer = timer
        timer.resume()
    }

    func stopMonitoring(commitSession: Bool = true) {
        finishSession(commit: commitSession)
    }

    private func markActivity() {
        guard var activeSession = session else { return }
        activeSession.lastActivityAt = Date()
        session = activeSession
    }

    private func handleKeyDown(_ event: NSEvent) {
        guard var activeSession = session else { return }

        activeSession.lastActivityAt = Date()

        if event.keyCode == 53 { // Escape
            session = activeSession
            finishSession(commit: false)
            return
        }

        if Constants.returnKeyCodes.contains(event.keyCode) {
            activeSession.sawEditIntent = true
            session = activeSession
            finishSession(commit: true)
            return
        }

        if didLikelyEditText(event) {
            activeSession.sawEditIntent = true
        }

        session = activeSession
    }

    private func didLikelyEditText(_ event: NSEvent) -> Bool {
        if Constants.deleteKeyCodes.contains(event.keyCode) {
            return true
        }

        if Constants.navigationKeyCodes.contains(event.keyCode) {
            return false
        }

        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .function])
        if modifiers.contains(.command) {
            let key = (event.charactersIgnoringModifiers ?? "").lowercased()
            return key == "v" || key == "x" || key == "z"
        }

        if modifiers.contains(.option) || modifiers.contains(.control) || modifiers.contains(.function) {
            return false
        }

        guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else {
            return false
        }

        return chars.unicodeScalars.contains { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
        }
    }

    private func tick() {
        guard let activeSession = session else {
            finishSession(commit: false)
            return
        }

        let now = Date()
        if now.timeIntervalSince(activeSession.startedAt) >= Constants.maxSessionDuration {
            finishSession(commit: true)
            return
        }

        if now.timeIntervalSince(activeSession.lastActivityAt) >= Constants.idleTimeout {
            finishSession(commit: true)
        }
    }

    private func finishSession(commit: Bool) {
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
            self.globalKeyMonitor = nil
        }

        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }

        sessionTimer?.cancel()
        sessionTimer = nil

        guard let completedSession = session else {
            return
        }

        session = nil

        guard commit else {
            return
        }

        let original = normalizedReferenceText(for: completedSession)
        guard !original.isEmpty else { return }

        guard let latest = latestFocusedText(for: completedSession) else { return }
        let corrected = latest.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !corrected.isEmpty, corrected != original else { return }

        // If no editing key events were seen, still allow learning only when text changed materially.
        if !completedSession.sawEditIntent {
            let distance = abs(corrected.count - original.count)
            if distance <= 1 {
                return
            }
        }

        onCorrectionDetected?(
            SessionResult(
                originalText: original,
                correctedText: corrected,
                insertedText: completedSession.insertedText
            )
        )
    }

    private func normalizedReferenceText(for session: Session) -> String {
        if let baseline = session.baselineText?.trimmingCharacters(in: .whitespacesAndNewlines), !baseline.isEmpty {
            return baseline
        }
        return session.insertedText
    }

    private func latestFocusedText(for session: Session) -> String? {
        if let focusedElement = session.focusedElement,
           let value = readTextValue(for: focusedElement) {
            return value
        }

        if let focusedElement = focusedTextElement(),
           let value = readTextValue(for: focusedElement) {
            return value
        }

        return nil
    }

    private func readTextValue(for element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &valueRef
        )

        guard result == .success, let stringValue = valueRef as? String else {
            return nil
        }

        return stringValue
    }

    private func focusedTextElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )

        guard focusedResult == .success, let focusedRef else {
            return nil
        }

        guard CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            return nil
        }

        return unsafeBitCast(focusedRef, to: AXUIElement.self)
    }

    deinit {
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
        }
        sessionTimer?.cancel()
    }
}
