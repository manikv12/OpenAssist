import AppKit
import SwiftUI

enum AssistantRichTextRenderMode: Equatable {
    case streamingPlain
    case streamingMarkdown
    case finalPlain
    case finalMarkdown
}

enum AssistantRichTextVariant: Equatable {
    case chat(textScale: CGFloat)
    case orbDone
}

struct AssistantRichTextView: View {
    let contentID: String
    let text: String
    let mode: AssistantRichTextRenderMode
    let variant: AssistantRichTextVariant
    var preferredMaxWidth: CGFloat? = nil
    var selectionMessageID: String? = nil
    var selectionMessageText: String? = nil
    var selectionTracker: AssistantTextSelectionTracker? = nil

    @State private var measuredHeight: CGFloat = 22

    var body: some View {
        AssistantRichTextNativeView(
            contentID: contentID,
            text: text,
            mode: mode,
            variant: variant,
            selectionMessageID: selectionMessageID,
            selectionMessageText: selectionMessageText,
            selectionTracker: selectionTracker,
            measuredHeight: $measuredHeight
        )
        .frame(height: max(ceil(measuredHeight), 18))
        .frame(maxWidth: preferredMaxWidth ?? .infinity, alignment: .leading)
    }
}

private struct AssistantRichTextNativeView: NSViewRepresentable {
    let contentID: String
    let text: String
    let mode: AssistantRichTextRenderMode
    let variant: AssistantRichTextVariant
    let selectionMessageID: String?
    let selectionMessageText: String?
    let selectionTracker: AssistantTextSelectionTracker?
    @Binding var measuredHeight: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(measuredHeight: $measuredHeight)
    }

    func makeNSView(context: Context) -> AssistantRichTextContainerView {
        let view = AssistantRichTextContainerView()
        view.onMeasuredHeightChanged = { height in
            context.coordinator.updateMeasuredHeight(height)
        }
        view.apply(
            contentID: contentID,
            text: text,
            mode: mode,
            variant: variant,
            selectionMessageID: selectionMessageID,
            selectionMessageText: selectionMessageText,
            selectionTracker: selectionTracker
        )
        return view
    }

    func updateNSView(_ nsView: AssistantRichTextContainerView, context: Context) {
        nsView.onMeasuredHeightChanged = { height in
            context.coordinator.updateMeasuredHeight(height)
        }
        nsView.apply(
            contentID: contentID,
            text: text,
            mode: mode,
            variant: variant,
            selectionMessageID: selectionMessageID,
            selectionMessageText: selectionMessageText,
            selectionTracker: selectionTracker
        )
    }

    static func dismantleNSView(_ nsView: AssistantRichTextContainerView, coordinator: Coordinator) {
        nsView.unregisterSelection()
    }

    final class Coordinator {
        @Binding private var measuredHeight: CGFloat

        init(measuredHeight: Binding<CGFloat>) {
            _measuredHeight = measuredHeight
        }

        func updateMeasuredHeight(_ height: CGFloat) {
            let normalizedHeight = max(18, ceil(height))
            guard abs(normalizedHeight - measuredHeight) > 0.5 else { return }
            DispatchQueue.main.async {
                self.measuredHeight = normalizedHeight
            }
        }
    }
}

final class AssistantRichTextContainerView: NSView, NSTextViewDelegate {
    var onMeasuredHeightChanged: ((CGFloat) -> Void)?

    private let textView = AssistantInteractiveTextView(frame: .zero)
    private var currentContentID: String?
    private var currentText = ""
    private var currentMode: AssistantRichTextRenderMode = .finalPlain
    private var currentVariant: AssistantRichTextVariant = .chat(textScale: 1.0)
    private var currentSelectionMessageText: String?
    private var measuredHeight: CGFloat = 22
    private var lastLayoutWidth: CGFloat = 0
    private weak var selectionTracker: AssistantTextSelectionTracker?
    private var selectionMessageID: String?

    // Throttling for streaming markdown re-renders
    private var streamingThrottleTimer: Timer?
    private var pendingStreamingText: String?
    private static let streamingThrottleInterval: TimeInterval = 0.06

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        textView.delegate = self
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: bounds.width, height: .greatestFiniteMagnitude)
        textView.linkTextAttributes = [
            .foregroundColor: AssistantRichTextTheme.accentColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        updateSelectionAppearance()

        addSubview(textView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateSelectionAppearance()
        syncAppearanceAndRefreshContent()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSelectionAppearance()
        syncAppearanceAndRefreshContent()
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        guard width > 0 else { return }
        // Only re-measure if width actually changed
        if abs(width - lastLayoutWidth) > 0.5 {
            lastLayoutWidth = width
            updateTextViewFrame(for: width)
        } else {
            // Just update the text view frame size without re-measuring
            textView.frame = NSRect(x: 0, y: 0, width: width, height: measuredHeight)
        }
    }

    override var isFlipped: Bool {
        true
    }

    func apply(
        contentID: String,
        text: String,
        mode: AssistantRichTextRenderMode,
        variant: AssistantRichTextVariant,
        selectionMessageID: String?,
        selectionMessageText: String?,
        selectionTracker: AssistantTextSelectionTracker?,
        forceContentRefresh: Bool = false
    ) {
        let previousText = currentText
        let previousMode = currentMode
        let previousContentID = currentContentID
        let previousVariant = currentVariant
        let previousSelectionMessageID = self.selectionMessageID
        let previousSelectionTracker = self.selectionTracker

        textView.appearance = effectiveAppearance

        // Fast path: nothing changed, just ensure layout is correct
        let contentUnchanged = previousContentID == contentID
            && previousText == text
            && previousMode == mode
            && previousVariant == variant

        currentContentID = contentID
        currentText = text
        currentMode = mode
        currentVariant = variant
        self.selectionMessageID = selectionMessageID
        currentSelectionMessageText = selectionMessageText
        self.selectionTracker = selectionTracker

        if forceContentRefresh {
            cancelStreamingThrottle()
            textView.textStorage?.setAttributedString(
                AssistantRichTextFormatter.attributedText(
                    for: text,
                    mode: mode,
                    variant: variant
                )
            )
        } else if !contentUnchanged {
            lastLayoutWidth = 0 // Force re-measure after content change

            let isStreamingAppend = previousContentID == contentID
                && text.hasPrefix(previousText)
                && text.count > previousText.count

            if isStreamingAppend,
               previousMode == .streamingPlain,
               mode == .streamingPlain {
                // Fast path: append plain text delta directly
                let delta = String(text.dropFirst(previousText.count))
                appendStreamingDelta(delta)
            } else if isStreamingAppend,
                      (mode == .streamingMarkdown) {
                // Throttled path: coalesce streaming markdown re-renders
                // to avoid re-parsing the full text on every token.
                pendingStreamingText = text
                if streamingThrottleTimer == nil {
                    flushStreamingMarkdown()
                    streamingThrottleTimer = Timer.scheduledTimer(
                        withTimeInterval: Self.streamingThrottleInterval,
                        repeats: true
                    ) { [weak self] _ in
                        self?.flushStreamingMarkdown()
                    }
                }
                return // Skip immediate layout; flushStreamingMarkdown handles it
            } else {
                // Full re-render (mode change, new content ID, or final render)
                cancelStreamingThrottle()
                textView.textStorage?.setAttributedString(
                    AssistantRichTextFormatter.attributedText(
                        for: text,
                        mode: mode,
                        variant: variant
                    )
                )
            }
        } else {
            // Content unchanged but may be transitioning away from streaming
            if mode != .streamingMarkdown && mode != .streamingPlain {
                cancelStreamingThrottle()
            }
        }

        if let selectionMessageID,
           let selectionMessageText,
           let selectionTracker {
            selectionTracker.register(
                textViews: [textView],
                messageID: selectionMessageID,
                messageText: selectionMessageText
            )
        } else {
            if let previousSelectionMessageID, let previousSelectionTracker {
                previousSelectionTracker.unregister(messageID: previousSelectionMessageID)
            }
        }

        updateTextViewFrame(for: bounds.width)
    }

    func unregisterSelection() {
        guard let selectionMessageID, let selectionTracker else { return }
        selectionTracker.unregister(messageID: selectionMessageID)
    }

    func textView(
        _ textView: NSTextView,
        clickedOnLink link: Any,
        at charIndex: Int
    ) -> Bool {
        guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) else {
            return false
        }
        return AssistantRichTextLinkOpener.open(url)
    }

    private func flushStreamingMarkdown() {
        guard let text = pendingStreamingText else {
            cancelStreamingThrottle()
            return
        }
        pendingStreamingText = nil
        textView.textStorage?.setAttributedString(
            AssistantRichTextFormatter.attributedText(
                for: text,
                mode: .streamingMarkdown,
                variant: currentVariant
            )
        )
        updateTextViewFrame(for: bounds.width)
    }

    private func cancelStreamingThrottle() {
        streamingThrottleTimer?.invalidate()
        streamingThrottleTimer = nil
        if pendingStreamingText != nil {
            flushStreamingMarkdown()
        }
    }

    private func syncAppearanceAndRefreshContent() {
        textView.appearance = effectiveAppearance
        guard let currentContentID else { return }

        apply(
            contentID: currentContentID,
            text: currentText,
            mode: currentMode,
            variant: currentVariant,
            selectionMessageID: selectionMessageID,
            selectionMessageText: currentSelectionMessageText,
            selectionTracker: selectionTracker,
            forceContentRefresh: true
        )
    }

    private func updateSelectionAppearance() {
        let selectionForeground = AppVisualTheme.isDarkAppearance
            ? NSColor.white
            : NSColor.labelColor

        textView.selectedTextAttributes = [
            .foregroundColor: selectionForeground
        ]
    }

    private func appendStreamingDelta(_ delta: String) {
        guard let normalizedDelta = delta.nonEmpty else { return }
        let attributedDelta = AssistantRichTextFormatter.attributedText(
            for: normalizedDelta,
            mode: .streamingPlain,
            variant: currentVariant
        )
        textView.textStorage?.append(attributedDelta)
    }

    private func updateTextViewFrame(for width: CGFloat) {
        let availableWidth = max(width, 1)
        textView.frame = NSRect(x: 0, y: 0, width: availableWidth, height: measuredHeight)
        textView.textContainer?.containerSize = NSSize(width: availableWidth, height: .greatestFiniteMagnitude)

        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            return
        }

        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let nextHeight = ceil(
            usedRect.height
                + (textView.textContainerInset.height * 2)
                + 2
        )
        let normalizedHeight = max(18, nextHeight)
        if abs(normalizedHeight - measuredHeight) > 0.5 {
            measuredHeight = normalizedHeight
            textView.frame.size.height = normalizedHeight
            invalidateIntrinsicContentSize()
            onMeasuredHeightChanged?(normalizedHeight)
        }
    }
}

final class AssistantInteractiveTextView: NSTextView {
    override func mouseDown(with event: NSEvent) {
        activateWindowForSelectionIfNeeded()
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        activateWindowForSelectionIfNeeded()
        super.rightMouseDown(with: event)
    }

    private func activateWindowForSelectionIfNeeded() {
        guard let panel = window as? NSPanel else { return }
        guard panel.styleMask.contains(.nonactivatingPanel) else { return }

        NSApp?.activate(ignoringOtherApps: true)
        panel.makeKey()
        panel.makeMain()
    }
}

private enum AssistantRichTextLinkOpener {
    static func open(_ url: URL) -> Bool {
        AssistantWorkspaceFileOpener.open(url)
    }
}

enum AssistantRichTextFormatter {
    static func attributedText(
        for text: String,
        mode: AssistantRichTextRenderMode,
        variant: AssistantRichTextVariant
    ) -> NSAttributedString {
        switch mode {
        case .streamingPlain, .finalPlain:
            return plainAttributedText(for: text, variant: variant)
        case .streamingMarkdown, .finalMarkdown:
            return markdownAttributedText(for: text, variant: variant)
        }
    }

    private static func plainAttributedText(
        for text: String,
        variant: AssistantRichTextVariant
    ) -> NSAttributedString {
        let theme = AssistantRichTextTheme(variant: variant)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        paragraphStyle.lineSpacing = theme.lineSpacing
        paragraphStyle.paragraphSpacing = theme.paragraphSpacing

        return NSAttributedString(
            string: text,
            attributes: [
                .font: theme.bodyFont,
                .foregroundColor: theme.textColor,
                .paragraphStyle: paragraphStyle
            ]
        )
    }

    private static func markdownAttributedText(
        for text: String,
        variant: AssistantRichTextVariant
    ) -> NSAttributedString {
        let theme = AssistantRichTextTheme(variant: variant)
        let output = NSMutableAttributedString()
        let normalizedText = text.replacingOccurrences(of: "\r\n", with: "\n")

        for segment in AssistantMarkdownSegment.parse(from: normalizedText) {
            switch segment.kind {
            case .codeBlock(let language, let code):
                appendCodeBlock(
                    code,
                    language: language,
                    to: output,
                    theme: theme
                )
            case .markdown(let value):
                appendMarkdownSegment(value, to: output, theme: theme)
            }
        }

        trimTrailingWhitespaceLines(in: output)
        return output
    }

    private static func appendMarkdownSegment(
        _ markdown: String,
        to output: NSMutableAttributedString,
        theme: AssistantRichTextTheme
    ) {
        let lines = markdown.components(separatedBy: "\n")
        var paragraphLines: [String] = []
        var quoteLines: [String] = []
        var listItems: [AssistantListItem] = []
        var index = 0

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            let paragraphText = paragraphLines.joined(separator: " ")
            appendParagraph(paragraphText, to: output, theme: theme)
            paragraphLines.removeAll(keepingCapacity: true)
        }

        func flushQuote() {
            guard !quoteLines.isEmpty else { return }
            let quoteText = quoteLines.joined(separator: "\n")
            appendBlockquote(quoteText, to: output, theme: theme)
            quoteLines.removeAll(keepingCapacity: true)
        }

        func flushList() {
            guard !listItems.isEmpty else { return }
            appendList(listItems, to: output, theme: theme)
            listItems.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                flushQuote()
                flushList()
                index += 1
                continue
            }

            if let tableLines = consumeTableLines(from: lines, startIndex: index) {
                flushParagraph()
                flushQuote()
                flushList()
                appendPreformattedBlock(tableLines.joined(separator: "\n"), to: output, theme: theme)
                index += tableLines.count
                continue
            }

            if looksLikeRawHTML(trimmed) {
                flushParagraph()
                flushQuote()
                flushList()
                appendPreformattedBlock(trimmed, to: output, theme: theme)
                index += 1
                continue
            }

            if isHorizontalRule(trimmed) {
                flushParagraph()
                flushQuote()
                flushList()
                appendHorizontalRule(to: output, theme: theme)
                index += 1
                continue
            }

            if let heading = parseHeading(trimmed) {
                flushParagraph()
                flushQuote()
                flushList()
                appendHeading(heading.text, level: heading.level, to: output, theme: theme)
                index += 1
                continue
            }

            if let quoteLine = parseBlockquote(trimmed) {
                flushParagraph()
                flushList()
                quoteLines.append(quoteLine)
                index += 1
                continue
            }

            if let listItem = parseListItem(line) {
                flushParagraph()
                flushQuote()
                listItems.append(listItem)
                index += 1
                continue
            }

            flushQuote()
            flushList()
            paragraphLines.append(trimmed)
            index += 1
        }

        flushParagraph()
        flushQuote()
        flushList()
    }

    private static func appendHeading(
        _ text: String,
        level: Int,
        to output: NSMutableAttributedString,
        theme: AssistantRichTextTheme
    ) {
        let attributed = AssistantInlineMarkdownFormatter.parse(
            text,
            theme: theme,
            font: theme.headingFont(for: level),
            color: theme.headingColor
        )
        applyParagraphStyle(
            to: attributed,
            paragraphStyle: theme.headingParagraphStyle(for: level)
        )
        appendBlock(attributed, to: output)
    }

    private static func appendParagraph(
        _ text: String,
        to output: NSMutableAttributedString,
        theme: AssistantRichTextTheme
    ) {
        let attributed = AssistantInlineMarkdownFormatter.parse(
            text,
            theme: theme,
            font: theme.bodyFont,
            color: theme.textColor
        )
        applyParagraphStyle(to: attributed, paragraphStyle: theme.bodyParagraphStyle)
        appendBlock(attributed, to: output)
    }

    private static func appendBlockquote(
        _ text: String,
        to output: NSMutableAttributedString,
        theme: AssistantRichTextTheme
    ) {
        let attributed = NSMutableAttributedString(string: "▎ ", attributes: [
            .font: theme.bodyFont,
            .foregroundColor: theme.blockquoteAccentColor
        ])
        attributed.append(
            AssistantInlineMarkdownFormatter.parse(
                text,
                theme: theme,
                font: theme.bodyItalicFont,
                color: theme.blockquoteTextColor
            )
        )
        applyParagraphStyle(to: attributed, paragraphStyle: theme.blockquoteParagraphStyle)
        appendBlock(attributed, to: output)
    }

    private static func appendList(
        _ items: [AssistantListItem],
        to output: NSMutableAttributedString,
        theme: AssistantRichTextTheme
    ) {
        var indentationStack: [Int] = []
        var nextOrderedNumberByLevel: [Int: Int] = [:]

        for item in items {
            let nestingLevel = resolveListNestingLevel(
                for: item.indentWidth,
                indentationStack: &indentationStack
            )
            for level in nextOrderedNumberByLevel.keys where level > nestingLevel {
                nextOrderedNumberByLevel.removeValue(forKey: level)
            }

            let prefix: String
            switch item.style {
            case .unordered:
                prefix = "• "
            case .ordered(let start):
                let number = nextOrderedNumberByLevel[nestingLevel] ?? start
                prefix = "\(number). "
                nextOrderedNumberByLevel[nestingLevel] = number + 1
            }

            let attributed = NSMutableAttributedString(string: prefix, attributes: [
                .font: theme.bodyFont,
                .foregroundColor: theme.textColor
            ])
            attributed.append(
                AssistantInlineMarkdownFormatter.parse(
                    item.text,
                    theme: theme,
                    font: theme.bodyFont,
                    color: theme.textColor
                )
            )
            applyParagraphStyle(
                to: attributed,
                paragraphStyle: theme.listParagraphStyle(
                    forNestingLevel: nestingLevel,
                    markerText: prefix
                )
            )
            appendBlock(attributed, to: output)
        }
    }

    private static func appendCodeBlock(
        _ code: String,
        language: String?,
        to output: NSMutableAttributedString,
        theme: AssistantRichTextTheme
    ) {
        let block = NSMutableAttributedString()
        if let language = language?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            let label = NSAttributedString(
                string: "\(language.uppercased())\n",
                attributes: [
                    .font: theme.codeLabelFont,
                    .foregroundColor: theme.mutedTextColor
                ]
            )
            block.append(label)
        }

        let lang = language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let highlighted: NSAttributedString
        if lang == "json" || lang == "jsonc" {
            highlighted = AssistantSyntaxHighlighter.highlightJSON(
                code: code, font: theme.codeFont, baseColor: theme.codeTextColor
            )
        } else if lang == "yaml" || lang == "yml" {
            highlighted = AssistantSyntaxHighlighter.highlightYAML(
                code: code, font: theme.codeFont, baseColor: theme.codeTextColor
            )
        } else {
            highlighted = AssistantSyntaxHighlighter.highlight(
                code: code, language: language, font: theme.codeFont, baseColor: theme.codeTextColor
            )
        }
        block.append(highlighted)

        applyParagraphStyle(to: block, paragraphStyle: theme.codeParagraphStyle)
        block.addAttributes([
            .backgroundColor: theme.codeBackgroundColor
        ], range: NSRange(location: 0, length: block.length))
        appendBlock(block, to: output)
    }

    private static func appendPreformattedBlock(
        _ text: String,
        to output: NSMutableAttributedString,
        theme: AssistantRichTextTheme
    ) {
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: theme.codeFont,
                .foregroundColor: theme.textColor,
                .backgroundColor: theme.codeBackgroundColor
            ]
        )
        applyParagraphStyle(to: attributed, paragraphStyle: theme.codeParagraphStyle)
        appendBlock(attributed, to: output)
    }

    private static func appendBlock(
        _ block: NSMutableAttributedString,
        to output: NSMutableAttributedString
    ) {
        if output.length > 0 {
            output.append(NSAttributedString(string: "\n"))
        }
        output.append(block)
    }

    private static func applyParagraphStyle(
        to attributed: NSMutableAttributedString,
        paragraphStyle: NSParagraphStyle
    ) {
        attributed.addAttribute(
            .paragraphStyle,
            value: paragraphStyle,
            range: NSRange(location: 0, length: attributed.length)
        )
    }

    private static func trimTrailingWhitespaceLines(in attributed: NSMutableAttributedString) {
        while attributed.string.hasSuffix("\n") {
            attributed.deleteCharacters(in: NSRange(location: attributed.length - 1, length: 1))
        }
    }

    private static func isHorizontalRule(_ line: String) -> Bool {
        let stripped = line.replacingOccurrences(of: " ", with: "")
        guard stripped.count >= 3 else { return false }
        let allDashes = stripped.allSatisfy { $0 == "-" }
        let allStars = stripped.allSatisfy { $0 == "*" }
        let allUnderscores = stripped.allSatisfy { $0 == "_" }
        return allDashes || allStars || allUnderscores
    }

    private static func appendHorizontalRule(
        to output: NSMutableAttributedString,
        theme: AssistantRichTextTheme
    ) {
        let rule = NSMutableAttributedString(
            string: "\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}",
            attributes: [
                .font: NSFont.systemFont(ofSize: 4, weight: .ultraLight),
                .foregroundColor: theme.mutedTextColor.withAlphaComponent(0.25)
            ]
        )
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byClipping
        style.paragraphSpacing = theme.paragraphSpacing
        style.paragraphSpacingBefore = theme.paragraphSpacing
        rule.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: rule.length))
        appendBlock(rule, to: output)
    }

    private static func parseHeading(_ line: String) -> (level: Int, text: String)? {
        let prefixLength = line.prefix { $0 == "#" }.count
        guard (1...3).contains(prefixLength) else { return nil }
        let remaining = line.dropFirst(prefixLength).trimmingCharacters(in: .whitespaces)
        guard !remaining.isEmpty else { return nil }
        return (prefixLength, remaining)
    }

    private static func parseBlockquote(_ line: String) -> String? {
        guard line.hasPrefix(">") else { return nil }
        return String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
    }

    private static func parseListItem(_ line: String) -> AssistantListItem? {
        let indentWidth = leadingIndentWidth(in: line)
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            return AssistantListItem(
                style: .unordered,
                text: String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces),
                indentWidth: indentWidth
            )
        }

        guard let match = trimmed.range(
            of: #"^(\d+)\.\s+(.+)$"#,
            options: .regularExpression
        ) else {
            return nil
        }
        let components = String(trimmed[match]).split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard components.count == 2,
              let number = Int(components[0].trimmingCharacters(in: .whitespaces)),
              let remainder = components[1].trimmingCharacters(in: .whitespaces).nonEmpty else {
            return nil
        }
        return AssistantListItem(
            style: .ordered(start: number),
            text: remainder,
            indentWidth: indentWidth
        )
    }

    private static func resolveListNestingLevel(
        for indentWidth: Int,
        indentationStack: inout [Int]
    ) -> Int {
        let normalizedIndent = max(0, indentWidth)

        guard !indentationStack.isEmpty else {
            indentationStack = [normalizedIndent]
            return 0
        }

        while indentationStack.count > 1,
              normalizedIndent < indentationStack.last ?? 0 {
            indentationStack.removeLast()
        }

        if let existingLevel = indentationStack.lastIndex(of: normalizedIndent) {
            if existingLevel + 1 < indentationStack.count {
                indentationStack.removeSubrange((existingLevel + 1)..<indentationStack.count)
            }
            return existingLevel
        }

        if normalizedIndent <= indentationStack[0] {
            indentationStack = [normalizedIndent]
            return 0
        }

        indentationStack.append(normalizedIndent)
        return indentationStack.count - 1
    }

    private static func leadingIndentWidth(in line: String) -> Int {
        var width = 0
        for character in line {
            switch character {
            case " ":
                width += 1
            case "\t":
                width += 4
            default:
                return width
            }
        }
        return width
    }

    private static func consumeTableLines(
        from lines: [String],
        startIndex: Int
    ) -> [String]? {
        guard startIndex + 1 < lines.count else { return nil }
        let header = lines[startIndex].trimmingCharacters(in: .whitespaces)
        let separator = lines[startIndex + 1].trimmingCharacters(in: .whitespaces)
        guard header.contains("|"),
              separator.range(of: #"^[\|\s:-]+$"#, options: .regularExpression) != nil else {
            return nil
        }

        var collected = [lines[startIndex], lines[startIndex + 1]]
        var index = startIndex + 2
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed.contains("|") else { break }
            collected.append(line)
            index += 1
        }
        return collected
    }

    private static func looksLikeRawHTML(_ line: String) -> Bool {
        line.hasPrefix("<") && line.hasSuffix(">")
    }
}

private struct AssistantListItem {
    let style: AssistantListStyle
    let text: String
    let indentWidth: Int
}

private enum AssistantListStyle: Equatable {
    case unordered
    case ordered(start: Int)
}

private enum AssistantInlineMarkdownFormatter {
    private struct FontTraits: OptionSet {
        let rawValue: Int

        static let bold = FontTraits(rawValue: 1 << 0)
        static let italic = FontTraits(rawValue: 1 << 1)
        static let code = FontTraits(rawValue: 1 << 2)
    }

    static func parse(
        _ text: String,
        theme: AssistantRichTextTheme,
        font: NSFont,
        color: NSColor
    ) -> NSMutableAttributedString {
        parse(text, theme: theme, baseFont: font, baseColor: color, traits: [])
    }

    private static func parse(
        _ text: String,
        theme: AssistantRichTextTheme,
        baseFont: NSFont,
        baseColor: NSColor,
        traits: FontTraits
    ) -> NSMutableAttributedString {
        let output = NSMutableAttributedString()
        var index = text.startIndex

        while index < text.endIndex {
            if text[index...].hasPrefix("`"),
               let closingIndex = text[text.index(after: index)...].firstIndex(of: "`") {
                let codeText = String(text[text.index(after: index)..<closingIndex])
                output.append(
                    makeText(
                        codeText,
                        font: theme.codeInlineFont,
                        color: theme.codeTextColor,
                        backgroundColor: theme.inlineCodeBackgroundColor
                    )
                )
                index = text.index(after: closingIndex)
                continue
            }

            if text[index...].hasPrefix("["),
               let closingBracket = text[index...].firstIndex(of: "]"),
               closingBracket < text.endIndex,
               text.index(after: closingBracket) < text.endIndex,
               text[text.index(after: closingBracket)] == "(",
               let closingParen = text[text.index(after: closingBracket)...].firstIndex(of: ")") {
                let labelRange = text.index(after: index)..<closingBracket
                let urlRange = text.index(closingBracket, offsetBy: 2)..<closingParen
                let labelText = String(text[labelRange])
                let urlText = String(text[urlRange])
                let label = parse(
                    labelText,
                    theme: theme,
                    baseFont: resolvedFont(
                        theme: theme,
                        baseFont: baseFont,
                        traits: traits
                    ),
                    baseColor: theme.linkColor,
                    traits: traits
                )
                let linkRange = NSRange(location: 0, length: label.length)
                if let url = URL(string: urlText) {
                    label.addAttribute(.link, value: url, range: linkRange)
                }
                label.addAttributes([
                    .foregroundColor: theme.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue
                ], range: linkRange)
                output.append(label)
                index = text.index(after: closingParen)
                continue
            }

            if text[index...].hasPrefix("**") {
                let searchStart = text.index(index, offsetBy: 2)
                if let closingRange = text[searchStart...].range(of: "**") {
                    let innerText = String(text[searchStart..<closingRange.lowerBound])
                    output.append(
                        parse(
                            innerText,
                            theme: theme,
                            baseFont: baseFont,
                            baseColor: baseColor,
                            traits: traits.union(.bold)
                        )
                    )
                    index = closingRange.upperBound
                    continue
                }
            }

            if text[index] == "*" {
                let searchStart = text.index(after: index)
                if let closingRange = text[searchStart...].range(of: "*") {
                    let innerText = String(text[searchStart..<closingRange.lowerBound])
                    output.append(
                        parse(
                            innerText,
                            theme: theme,
                            baseFont: baseFont,
                            baseColor: baseColor,
                            traits: traits.union(.italic)
                        )
                    )
                    index = closingRange.upperBound
                    continue
                }
            }

            let nextIndex = nextSpecialMarkerIndex(in: text, from: index) ?? text.endIndex
            if nextIndex == index {
                output.append(
                    makeText(
                        String(text[index]),
                        font: resolvedFont(theme: theme, baseFont: baseFont, traits: traits),
                        color: baseColor
                    )
                )
                index = text.index(after: index)
                continue
            }
            let chunk = String(text[index..<nextIndex])
            output.append(
                makeText(
                    chunk,
                    font: resolvedFont(theme: theme, baseFont: baseFont, traits: traits),
                    color: baseColor
                )
            )
            index = nextIndex
        }

        return output
    }

    private static func nextSpecialMarkerIndex(
        in text: String,
        from index: String.Index
    ) -> String.Index? {
        text[index...].firstIndex(where: { character in
            character == "`" || character == "[" || character == "*"
        })
    }

    private static func resolvedFont(
        theme: AssistantRichTextTheme,
        baseFont: NSFont,
        traits: FontTraits
    ) -> NSFont {
        if traits.contains(.code) {
            return theme.codeInlineFont
        }

        let weight: NSFont.Weight = traits.contains(.bold) ? .bold : .regular
        let font = theme.font(
            size: baseFont.pointSize,
            weight: weight,
            italic: traits.contains(.italic)
        )
        return font
    }

    private static func makeText(
        _ text: String,
        font: NSFont,
        color: NSColor,
        backgroundColor: NSColor? = nil
    ) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        if let backgroundColor {
            attributes[.backgroundColor] = backgroundColor
        }
        return NSAttributedString(string: text, attributes: attributes)
    }
}

private struct AssistantRichTextTheme {
    static let accentColor = NSColor(calibratedRed: 0.52, green: 0.76, blue: 1.0, alpha: 1.0)

    let bodyFont: NSFont
    let bodyItalicFont: NSFont
    let headingColor: NSColor
    let textColor: NSColor
    let mutedTextColor: NSColor
    let linkColor: NSColor
    let codeTextColor: NSColor
    let codeBackgroundColor: NSColor
    let inlineCodeBackgroundColor: NSColor
    let blockquoteTextColor: NSColor
    let blockquoteAccentColor: NSColor
    let paragraphSpacing: CGFloat
    let lineSpacing: CGFloat
    let codeFont: NSFont
    let codeInlineFont: NSFont
    let codeLabelFont: NSFont
    let bodyParagraphStyle: NSParagraphStyle
    let listBaseParagraphStyle: NSParagraphStyle
    let blockquoteParagraphStyle: NSParagraphStyle
    let codeParagraphStyle: NSParagraphStyle
    let listBaseIndent: CGFloat
    let listNestedIndent: CGFloat

    init(variant: AssistantRichTextVariant) {
        let isDarkAppearance = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        switch variant {
        case .chat(let textScale):
            let baseSize = 13.8 * max(textScale, 0.8)
            bodyFont = Self.font(size: baseSize, weight: .regular)
            bodyItalicFont = Self.font(size: baseSize, weight: .regular, italic: true)
            codeFont = NSFont.monospacedSystemFont(ofSize: 12.2 * max(textScale, 0.8), weight: .regular)
            codeInlineFont = NSFont.monospacedSystemFont(ofSize: 12 * max(textScale, 0.8), weight: .medium)
            codeLabelFont = NSFont.monospacedSystemFont(ofSize: 10.8 * max(textScale, 0.8), weight: .semibold)
            paragraphSpacing = 12
            lineSpacing = 3.0
            listBaseIndent = 4
            listNestedIndent = 18
        case .orbDone:
            bodyFont = Self.font(size: 13, weight: .regular)
            bodyItalicFont = Self.font(size: 13, weight: .regular, italic: true)
            codeFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            codeInlineFont = NSFont.monospacedSystemFont(ofSize: 11.8, weight: .regular)
            codeLabelFont = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .semibold)
            paragraphSpacing = 6
            lineSpacing = 1.8
            listBaseIndent = 4
            listNestedIndent = 16
        }

        headingColor = NSColor.labelColor
        textColor = NSColor.labelColor.withAlphaComponent(0.90)
        mutedTextColor = NSColor.secondaryLabelColor
        linkColor = Self.accentColor
        codeTextColor = isDarkAppearance
            ? NSColor.white.withAlphaComponent(0.92)
            : NSColor.labelColor.withAlphaComponent(0.90)
        codeBackgroundColor = isDarkAppearance
            ? NSColor(calibratedWhite: 0.16, alpha: 1.0)
            : NSColor(calibratedWhite: 0.95, alpha: 1.0)
        inlineCodeBackgroundColor = isDarkAppearance
            ? NSColor(calibratedWhite: 0.20, alpha: 1.0)
            : NSColor(calibratedWhite: 0.92, alpha: 1.0)
        blockquoteTextColor = NSColor.secondaryLabelColor
        blockquoteAccentColor = Self.accentColor.withAlphaComponent(0.55)

        let bodyStyle = NSMutableParagraphStyle()
        bodyStyle.lineBreakMode = .byWordWrapping
        bodyStyle.lineSpacing = lineSpacing
        bodyStyle.paragraphSpacing = paragraphSpacing
        bodyParagraphStyle = bodyStyle

        let listStyle = NSMutableParagraphStyle()
        listStyle.lineBreakMode = .byWordWrapping
        listStyle.lineSpacing = lineSpacing
        listStyle.paragraphSpacing = 6
        listBaseParagraphStyle = listStyle

        let quoteStyle = NSMutableParagraphStyle()
        quoteStyle.lineBreakMode = .byWordWrapping
        quoteStyle.lineSpacing = lineSpacing
        quoteStyle.paragraphSpacing = paragraphSpacing
        quoteStyle.headIndent = 16
        quoteStyle.firstLineHeadIndent = 0
        blockquoteParagraphStyle = quoteStyle

        let codeStyle = NSMutableParagraphStyle()
        codeStyle.lineBreakMode = .byWordWrapping
        codeStyle.lineSpacing = 1.2
        codeStyle.paragraphSpacing = 8
        codeStyle.firstLineHeadIndent = 10
        codeStyle.headIndent = 10
        codeStyle.paragraphSpacingBefore = 4
        codeParagraphStyle = codeStyle
    }

    func headingFont(for level: Int) -> NSFont {
        switch level {
        case 1:
            return font(size: bodyFont.pointSize + 5, weight: .bold)
        case 2:
            return font(size: bodyFont.pointSize + 2.5, weight: .bold)
        default:
            return font(size: bodyFont.pointSize + 1, weight: .semibold)
        }
    }

    func headingParagraphStyle(for level: Int) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.lineSpacing = max(1.4, lineSpacing - 0.4)
        style.paragraphSpacing = level == 1 ? 10 : 8
        style.paragraphSpacingBefore = level == 1 ? 18 : 14
        return style
    }

    func listParagraphStyle(
        forNestingLevel nestingLevel: Int,
        markerText: String
    ) -> NSParagraphStyle {
        let style = (listBaseParagraphStyle.mutableCopy() as? NSMutableParagraphStyle)
            ?? NSMutableParagraphStyle()
        let leadingIndent = listBaseIndent + (CGFloat(nestingLevel) * listNestedIndent)
        let markerWidth = (markerText as NSString).size(withAttributes: [
            .font: bodyFont
        ]).width
        style.firstLineHeadIndent = leadingIndent
        style.headIndent = leadingIndent + markerWidth
        return style
    }

    func font(size: CGFloat, weight: NSFont.Weight, italic: Bool = false) -> NSFont {
        Self.font(size: size, weight: weight, italic: italic)
    }

    static func font(size: CGFloat, weight: NSFont.Weight, italic: Bool = false) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard italic else { return base }
        return NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
    }
}
