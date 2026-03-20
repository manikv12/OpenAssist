import AppKit
import ApplicationServices

enum AssistantSelectionTextResolver {
    struct SelectionSnapshot: Equatable {
        let selectedText: String
        let parentText: String
        let anchorRectOnScreen: NSRect
    }

    private struct PasteboardSnapshot {
        let items: [[Representation]]

        struct Representation {
            let type: NSPasteboard.PasteboardType
            let data: Data
        }
    }

    static func currentSelectedText() -> String? {
        if let directSelection = selectedTextFromActiveResponder() {
            return directSelection
        }

        return selectedTextUsingCopyFallback()
    }

    static func selectionSnapshot(in textView: NSTextView) -> SelectionSnapshot? {
        let fullText = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fullText.isEmpty,
              let selectedText = selectedText(in: textView),
              let anchorRect = selectionAnchorRect(in: textView) else {
            return nil
        }

        return SelectionSnapshot(
            selectedText: selectedText,
            parentText: fullText,
            anchorRectOnScreen: anchorRect
        )
    }

    static func currentSelectionSnapshot(
        parentText: String,
        fallbackTextView: NSTextView?
    ) -> SelectionSnapshot? {
        let normalizedParentText = parentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedParentText.isEmpty else { return nil }

        let selectedText = accessibilitySelectedText()
            ?? currentSelectedText()
            ?? fallbackTextView.flatMap(selectedText(in:))
        let anchorRect = accessibilitySelectionBounds()
            ?? fallbackTextView.flatMap(selectionAnchorRect(in:))

        guard let selectedText,
              let anchorRect else {
            return nil
        }

        let normalizedSelection = selectedText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
        guard let normalizedSelection else { return nil }

        return SelectionSnapshot(
            selectedText: normalizedSelection,
            parentText: normalizedParentText,
            anchorRectOnScreen: anchorRect
        )
    }

    private static func selectedTextFromActiveResponder() -> String? {
        let candidateWindows = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }

        for window in candidateWindows {
            if let text = selectedText(from: window.firstResponder) {
                return text
            }

            if let fieldEditor = window.fieldEditor(false, for: nil) as? NSTextView,
               let text = selectedText(in: fieldEditor) {
                return text
            }
        }

        return nil
    }

    private static func selectedText(from responder: NSResponder?) -> String? {
        var currentResponder = responder

        while let responder = currentResponder {
            if let textView = responder as? NSTextView,
               let text = selectedText(in: textView) {
                return text
            }

            currentResponder = responder.nextResponder
        }

        return nil
    }

    static func selectedText(in textView: NSTextView) -> String? {
        let fullText = textView.string as NSString
        let selections = textView.selectedRanges.map(\.rangeValue)

        let fragments = selections.compactMap { range -> String? in
            guard range.length > 0,
                  range.location != NSNotFound,
                  NSMaxRange(range) <= fullText.length else {
                return nil
            }

            let fragment = fullText.substring(with: range)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return fragment.isEmpty ? nil : fragment
        }

        guard !fragments.isEmpty else { return nil }
        return fragments.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    private static func selectionAnchorRect(in textView: NSTextView) -> NSRect? {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let window = textView.window else {
            return nil
        }

        let ranges = textView.selectedRanges
            .map(\.rangeValue)
            .filter { range in
                range.length > 0
                    && range.location != NSNotFound
                    && NSMaxRange(range) <= (textView.string as NSString).length
            }

        guard !ranges.isEmpty else { return nil }

        var unionRect: NSRect?
        let containerOrigin = textView.textContainerOrigin

        for range in ranges {
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            rect.origin.x += containerOrigin.x
            rect.origin.y += containerOrigin.y

            guard rect.width.isFinite,
                  rect.height.isFinite,
                  rect.width > 0,
                  rect.height > 0 else {
                continue
            }

            let rectInWindow = textView.convert(rect, to: nil)
            let rectOnScreen = window.convertToScreen(rectInWindow)
            unionRect = unionRect?.union(rectOnScreen) ?? rectOnScreen
        }

        return unionRect
    }

    private static func selectedTextUsingCopyFallback() -> String? {
        let pasteboard = NSPasteboard.general
        let snapshot = capturePasteboardSnapshot(from: pasteboard)

        defer {
            restorePasteboardSnapshot(snapshot, to: pasteboard)
        }

        guard NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) else {
            return nil
        }

        return pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
    }

    private static func accessibilitySelectedText() -> String? {
        guard AXIsProcessTrusted(),
              let focusedElement = focusedElement() else {
            return nil
        }

        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &valueRef
        )
        guard result == .success else {
            return nil
        }

        return (valueRef as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
    }

    private static func accessibilitySelectionBounds() -> NSRect? {
        guard AXIsProcessTrusted(),
              let focusedElement = focusedElement() else {
            return nil
        }

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

        return normalizeAccessibilityRectToScreen(cgRect)
    }

    private static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        guard result == .success,
              let focusedRef,
              CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(focusedRef, to: AXUIElement.self)
    }

    private static func capturePasteboardSnapshot(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = pasteboard.pasteboardItems?.map { item in
            item.types.compactMap { type -> PasteboardSnapshot.Representation? in
                guard let data = item.data(forType: type) else { return nil }
                return PasteboardSnapshot.Representation(type: type, data: data)
            }
        } ?? []

        return PasteboardSnapshot(items: items)
    }

    private static func restorePasteboardSnapshot(_ snapshot: PasteboardSnapshot, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()

        guard !snapshot.items.isEmpty else { return }

        let restoredItems: [NSPasteboardItem] = snapshot.items.compactMap { representations in
            let item = NSPasteboardItem()
            var wroteAnyRepresentation = false

            for representation in representations {
                item.setData(representation.data, forType: representation.type)
                wroteAnyRepresentation = true
            }

            return wroteAnyRepresentation ? item : nil
        }

        if !restoredItems.isEmpty {
            pasteboard.writeObjects(restoredItems)
        }
    }

    private static func normalizeAccessibilityRectToScreen(_ rect: CGRect) -> NSRect? {
        if let flipped = normalizedFlippedRect(for: rect) {
            return flipped
        }

        let direct = NSRect(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
        let directPoint = NSPoint(x: direct.midX, y: direct.midY)
        return screenContaining(point: directPoint) != nil ? direct : nil
    }

    private static func normalizedFlippedRect(for rect: CGRect) -> NSRect? {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let flippedY = primaryHeight - rect.origin.y - rect.height
        let flipped = NSRect(x: rect.origin.x, y: flippedY, width: rect.width, height: rect.height)
        let flippedPoint = NSPoint(x: flipped.midX, y: flipped.midY)
        return screenContaining(point: flippedPoint) == nil ? nil : flipped
    }

    private static func screenContaining(point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { screen in
            screen.frame.contains(point)
        }
    }
}
