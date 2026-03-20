import AppKit

@MainActor
final class AssistantTextSelectionTracker: ObservableObject {
    struct SelectionContext: Equatable {
        let messageID: String
        let selectedText: String
        let parentMessageText: String
        let anchorRectOnScreen: NSRect
    }

    private struct Registration {
        weak var textView: NSTextView?
        let messageID: String
        let messageText: String
    }

    static let shared = AssistantTextSelectionTracker()

    @Published private(set) var selectionContext: SelectionContext?

    private var observers: [NSObjectProtocol] = []
    private var registrations: [ObjectIdentifier: Registration] = [:]

    private init() {
        let center = NotificationCenter.default

        observers.append(
            center.addObserver(
                forName: NSTextView.didChangeSelectionNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.handleSelectionChange(notification.object as? NSTextView)
                }
            }
        )

        observers.append(
            center.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.selectionContext = nil
                }
            }
        )
    }

    deinit {
        let center = NotificationCenter.default
        observers.forEach(center.removeObserver)
    }

    func register(textViews: [NSTextView], messageID: String, messageText: String) {
        removeRegistrations(for: messageID)

        for textView in textViews {
            registrations[ObjectIdentifier(textView)] = Registration(
                textView: textView,
                messageID: messageID,
                messageText: messageText
            )
        }

        pruneRegistrations()
    }

    func unregister(messageID: String) {
        removeRegistrations(for: messageID)

        if selectionContext?.messageID == messageID {
            selectionContext = nil
        }
    }

    func clearSelection() {
        selectionContext = nil
    }

    private func handleSelectionChange(_ textView: NSTextView?) {
        pruneRegistrations()

        guard let textView,
              let registration = registrations[ObjectIdentifier(textView)],
              let snapshot = AssistantSelectionTextResolver.currentSelectionSnapshot(
                parentText: registration.messageText,
                fallbackTextView: textView
              ) else {
            selectionContext = nil
            return
        }

        selectionContext = SelectionContext(
            messageID: registration.messageID,
            selectedText: snapshot.selectedText,
            parentMessageText: registration.messageText,
            anchorRectOnScreen: snapshot.anchorRectOnScreen
        )
    }

    private func pruneRegistrations() {
        registrations = registrations.filter { _, registration in
            registration.textView != nil
        }
    }

    private func removeRegistrations(for messageID: String) {
        registrations = registrations.filter { _, registration in
            registration.messageID != messageID && registration.textView != nil
        }
    }
}
