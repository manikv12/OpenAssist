import AppKit

@MainActor
private func assistantComposerResolvedColor(
    _ colorProvider: @autoclosure @escaping () -> NSColor,
    for appearance: NSAppearance
) -> NSColor {
    var resolved = colorProvider()
    appearance.performAsCurrentDrawingAppearance {
        resolved = colorProvider()
    }
    return resolved
}

@MainActor
func assistantComposerResolvedTextColor(for appearance: NSAppearance) -> NSColor {
    assistantComposerResolvedColor(NSColor.labelColor, for: appearance).withAlphaComponent(0.92)
}

@MainActor
func assistantComposerResolvedPlaceholderColor(for appearance: NSAppearance) -> NSColor {
    assistantComposerResolvedColor(NSColor.labelColor, for: appearance).withAlphaComponent(0.38)
}

@MainActor
func applyAssistantComposerAppearance(
    to textView: NSTextView,
    appearance explicitAppearance: NSAppearance? = nil
) {
    let resolvedAppearance = explicitAppearance ?? textView.effectiveAppearance
    let textColor = assistantComposerResolvedTextColor(for: resolvedAppearance)
    let insertionColor = assistantComposerResolvedColor(NSColor.labelColor, for: resolvedAppearance)
    let selectionBackground = assistantComposerResolvedColor(
        NSColor.selectedContentBackgroundColor,
        for: resolvedAppearance
    )

    textView.appearance = resolvedAppearance
    textView.textColor = textColor
    textView.insertionPointColor = insertionColor

    var typingAttributes = textView.typingAttributes
    typingAttributes[.foregroundColor] = textColor
    textView.typingAttributes = typingAttributes

    textView.selectedTextAttributes = [
        .backgroundColor: selectionBackground,
        .foregroundColor: textColor
    ]

    if let storage = textView.textStorage, storage.length > 0 {
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: textColor, range: fullRange)
        storage.endEditing()
    }

    textView.needsDisplay = true
    textView.enclosingScrollView?.needsDisplay = true
}
