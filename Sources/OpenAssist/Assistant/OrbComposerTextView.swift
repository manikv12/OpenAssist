import AppKit
import SwiftUI

private func activateComposerWindowForEditing(_ window: NSWindow?) {
    guard let window else { return }
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
}

struct OrbComposerTextView: NSViewRepresentable {
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
        AssistantComposerBridge.shared.register(textView: textView, target: .assistantCompact)

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? OrbSubmittableTextView else { return }
        AssistantComposerBridge.shared.register(textView: textView, target: .assistantCompact)
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

final class OrbComposerScrollView: NSScrollView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        guard let textView = documentView as? NSTextView, textView.isEditable else {
            super.mouseDown(with: event)
            return
        }

        activateComposerWindowForEditing(window)
        window?.makeFirstResponder(textView)
        let insertionPoint = textView.string.utf16.count
        textView.setSelectedRange(NSRange(location: insertionPoint, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        textView.needsDisplay = true
    }
}

final class OrbSubmittableTextView: NSTextView {
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
            activateComposerWindowForEditing(window)
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
