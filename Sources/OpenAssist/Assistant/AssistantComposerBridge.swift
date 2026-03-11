import AppKit
import Foundation

@MainActor
final class AssistantComposerBridge {
    enum CaptureTarget: Equatable {
        case assistantWindow
        case assistantOrb
    }

    static let shared = AssistantComposerBridge()

    private final class Registration {
        weak var textView: NSTextView?
        let target: CaptureTarget

        init(textView: NSTextView, target: CaptureTarget) {
            self.textView = textView
            self.target = target
        }
    }

    private var registrations: [ObjectIdentifier: Registration] = [:]

    private init() {}

    func register(textView: NSTextView, target: CaptureTarget) {
        pruneRegistrations()
        let key = ObjectIdentifier(textView)
        if let existing = registrations[key] {
            existing.textView = textView
        } else {
            registrations[key] = Registration(textView: textView, target: target)
        }
    }

    func unregister(textView: NSTextView) {
        registrations.removeValue(forKey: ObjectIdentifier(textView))
        pruneRegistrations()
    }

    var canInsertIntoActiveComposer: Bool {
        activeRegistration != nil
    }

    var activeCaptureTarget: CaptureTarget? {
        activeRegistration?.target
    }

    @discardableResult
    func insert(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let registration = activeRegistration,
              let textView = registration.textView,
              let window = textView.window,
              canInsertIntoActiveComposer else {
            return false
        }

        if window.firstResponder !== textView {
            window.makeFirstResponder(textView)
        }

        textView.insertText(text, replacementRange: textView.selectedRange())
        return true
    }

    private var activeRegistration: Registration? {
        pruneRegistrations()

        guard NSApp.isActive else { return nil }

        if let keyWindow = NSApp.keyWindow {
            if let focused = registrations.values.first(where: { registration in
                guard let textView = registration.textView,
                      let window = textView.window else {
                    return false
                }
                return window === keyWindow && keyWindow.isVisible && keyWindow.firstResponder === textView
            }) {
                return focused
            }

            if let keyWindowMatch = registrations.values.first(where: { registration in
                guard let textView = registration.textView,
                      let window = textView.window else {
                    return false
                }
                return window === keyWindow && keyWindow.isVisible
            }) {
                return keyWindowMatch
            }
        }

        return registrations.values.first(where: { registration in
            guard let textView = registration.textView,
                  let window = textView.window else {
                return false
            }
            return window.isVisible && window.isKeyWindow
        })
    }

    private func pruneRegistrations() {
        registrations = registrations.filter { _, registration in
            registration.textView != nil
        }
    }
}
