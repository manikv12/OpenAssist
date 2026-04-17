import Foundation

struct TelegramRenderedText: Equatable, Sendable {
    let html: String
    let plainText: String
    let visibleSignature: String

    init(html: String, plainText: String) {
        let normalizedHTML = html.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPlainText = plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.html = normalizedHTML
        self.plainText = normalizedPlainText
        self.visibleSignature = MemoryIdentifier.stableHexDigest(
            for: "html:\(normalizedHTML)\nplain:\(normalizedPlainText)"
        )
    }
}

enum TelegramRemoteRenderer {
    static let messageCharacterLimit = 3500
    static let captionCharacterLimit = 900

    struct StreamPresentation {
        let text: String
        let signaturePrefix: String
        let allowsOverflow: Bool
    }

    private enum BlockKind: Equatable {
        case richText
        case code(language: String?)
    }

    private struct RenderedBlock: Equatable {
        let html: String
        let plainText: String
        let kind: BlockKind
    }

    private struct InlineRendering {
        let html: String
        let plainText: String
    }

    private struct TelegramListItem {
        let style: TelegramListStyle
        let text: String
        let indentWidth: Int
    }

    private enum TelegramListStyle: Equatable {
        case unordered
        case ordered(start: Int)
    }

    private static func providerUsageLine(for window: RateLimitWindow) -> String {
        var line = "\(providerWindowLabel(for: window)): \(window.usedPercent)% used (\(window.remainingPercent)% left)"
        if let resets = window.resetsInLabel {
            line += ", resets \(resets)"
        }
        return line
    }

    private static func providerWindowLabel(for window: RateLimitWindow) -> String {
        if window.windowDurationMins == 300 {
            return "5-hour"
        }
        if let mins = window.windowDurationMins, mins >= 10_080 {
            return "Weekly"
        }
        return window.windowLabel.isEmpty ? "Usage" : window.windowLabel
    }

    static func chunkText(_ text: String, limit: Int = messageCharacterLimit) -> [String] {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        guard normalized.count > limit else { return [normalized] }

        var chunks: [String] = []
        var remaining = normalized[...]

        while !remaining.isEmpty {
            if remaining.count <= limit {
                chunks.append(String(remaining).trimmingCharacters(in: .whitespacesAndNewlines))
                break
            }

            let endIndex = remaining.index(remaining.startIndex, offsetBy: limit)
            let candidate = remaining[..<endIndex]
            if let splitIndex = candidate.lastIndex(where: \.isNewline) {
                let part = remaining[..<splitIndex]
                chunks.append(String(part).trimmingCharacters(in: .whitespacesAndNewlines))
                remaining = remaining[remaining.index(after: splitIndex)...]
                continue
            }

            if let splitIndex = candidate.lastIndex(where: \.isWhitespace) {
                let part = remaining[..<splitIndex]
                chunks.append(String(part).trimmingCharacters(in: .whitespacesAndNewlines))
                remaining = remaining[remaining.index(after: splitIndex)...]
                continue
            }

            chunks.append(String(candidate).trimmingCharacters(in: .whitespacesAndNewlines))
            remaining = remaining[endIndex...]
        }

        return chunks.filter { !$0.isEmpty }
    }

    static func renderMessage(
        _ rawValue: String?,
        limit: Int = messageCharacterLimit
    ) -> [TelegramRenderedText] {
        let blocks = renderedBlocks(from: rawValue)
        guard !blocks.isEmpty else { return [] }
        return packBlocks(blocks, limit: limit)
    }

    static func renderSingleMessage(
        _ rawValue: String?,
        limit: Int = messageCharacterLimit
    ) -> TelegramRenderedText? {
        renderMessage(rawValue, limit: limit).first
    }

    static func renderCaption(
        _ rawValue: String?,
        fallback: String,
        limit: Int = captionCharacterLimit
    ) -> TelegramRenderedText {
        renderSingleMessage(rawValue, limit: limit)
            ?? renderSingleMessage(fallback, limit: limit)
            ?? TelegramRenderedText(
                html: escapeHTML(fallback),
                plainText: fallback
            )
    }

    static func transcriptPreviewText(
        sessionTitle: String,
        entries: [AssistantTranscriptEntry]
    ) -> String {
        let safeSessionTitle = telegramPlainText(sessionTitle) ?? sessionTitle
        guard !entries.isEmpty else {
            return """
            Session: \(safeSessionTitle)

            No messages yet.
            """
        }

        let previewLines = entries.suffix(12).map { entry in
            "\(roleLabel(for: entry.role)): \(collapsed(entry.text, maxLength: 240))"
        }

        return """
        Session: \(safeSessionTitle)
        Recent messages:

        \(previewLines.joined(separator: "\n\n"))
        """
    }

    static func catchUpText(snapshot: AssistantRemoteSessionSnapshot) -> String? {
        let entries = snapshot.transcriptEntries.filter { entry in
            switch entry.role {
            case .user, .assistant, .error:
                return entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            case .system, .status, .tool, .permission:
                return false
            }
        }.suffix(4)
        guard !entries.isEmpty else { return nil }

        let sessionTitle = telegramPlainText(snapshot.session.title) ?? snapshot.session.title
        var lines = ["Recent context from \(sessionTitle):", ""]
        for entry in entries {
            lines.append("\(roleLabel(for: entry.role)): \(collapsed(entry.text, maxLength: 180))")
            lines.append("")
        }

        return lines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sessionHeaderText(
        snapshot: AssistantRemoteSessionSnapshot,
        selectedPluginNames: [String] = []
    ) -> String {
        var lines = ["Session: \(displaySessionTitle(title: snapshot.session.title, isTemporary: snapshot.session.isTemporary))"]
        if snapshot.session.isTemporary {
            lines.append("Type: Temporary chat")
        }
        if let projectName = telegramPlainText(snapshot.session.projectName)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !projectName.isEmpty {
            lines.append("Project: \(projectName)")
        }
        if !selectedPluginNames.isEmpty {
            lines.append("Plugins: \(selectedPluginNames.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    static func toolActivityText(snapshot: AssistantRemoteSessionSnapshot) -> String? {
        let activeCalls = snapshot.toolCalls
        let recentCalls = snapshot.recentToolCalls

        guard !activeCalls.isEmpty || !recentCalls.isEmpty else { return nil }

        var lines = ["Tool activity", ""]

        if !activeCalls.isEmpty {
            lines.append("Active:")
            for call in activeCalls.prefix(4) {
                let line = call.detail?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                    .map { "• \(call.title): \(collapsed($0, maxLength: 90))" }
                    ?? "• \(call.title)"
                lines.append(line)
            }
            lines.append("")
        }

        if !recentCalls.isEmpty {
            lines.append("Recent:")
            for call in recentCalls.prefix(4) {
                let status = call.status.trimmingCharacters(in: .whitespacesAndNewlines)
                let detail = call.detail?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                if let detail {
                    lines.append("• \(call.title) [\(status)]: \(collapsed(detail, maxLength: 90))")
                } else {
                    lines.append("• \(call.title) [\(status)]")
                }
            }
        }

        return lines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func providerUsageText(
        status: AssistantRemoteStatusSnapshot,
        rateLimits: AccountRateLimits
    ) -> String {
        let sessionLine: String
        if status.selectedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty != nil {
            sessionLine = displaySessionTitle(
                title: status.selectedSessionTitle,
                isTemporary: status.selectedSessionIsTemporary
            )
        } else {
            sessionLine = "No session selected"
        }

        let modelLine = status.selectedModelSummary
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? "No model selected"

        var lines = [
            "Provider Usage",
            "Session: \(sessionLine)",
            "Backend: \(status.assistantBackendName)",
            "Model: \(modelLine)"
        ]

        if status.selectedSessionIsTemporary {
            lines.append("Type: Temporary chat")
        }

        guard let bucket = rateLimits.bucket(for: status.selectedModelID),
              bucket.primary != nil || bucket.secondary != nil else {
            lines.append("Provider: No provider usage reported yet for the selected model.")
            return lines.joined(separator: "\n")
        }

        lines.append("Provider: \(bucket.isDefaultCodex ? "Codex" : bucket.displayName)")

        if let primary = bucket.primary {
            lines.append(providerUsageLine(for: primary))
        }
        if let secondary = bucket.secondary {
            lines.append(providerUsageLine(for: secondary))
        }

        return lines.joined(separator: "\n")
    }

    static func displaySessionTitle(title: String?, isTemporary: Bool) -> String {
        let sanitizedTitle = (telegramPlainText(title) ?? title ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !sanitizedTitle.isEmpty {
            return sanitizedTitle
        }
        return isTemporary ? "Temporary Chat" : "New Session"
    }

    static func sessionMenuLabel(_ session: AssistantSessionSummary, isSelected: Bool) -> String {
        let prefix = isSelected ? "• " : ""
        let title = displaySessionTitle(title: session.title, isTemporary: session.isTemporary)
        if session.isTemporary {
            return "\(prefix)[Temp] \(title)"
        }
        return "\(prefix)\(title)"
    }

    static func streamMessageText(snapshot: AssistantRemoteSessionSnapshot) -> String? {
        streamPresentation(snapshot: snapshot)?.text
    }

    static func streamPresentation(snapshot: AssistantRemoteSessionSnapshot) -> StreamPresentation? {
        let currentTurnEntries: ArraySlice<AssistantTranscriptEntry>
        if let lastUserIndex = snapshot.transcriptEntries.lastIndex(where: { $0.role == .user }) {
            let nextIndex = snapshot.transcriptEntries.index(after: lastUserIndex)
            currentTurnEntries = snapshot.transcriptEntries[nextIndex...]
        } else {
            currentTurnEntries = snapshot.transcriptEntries[...]
        }

        if let latestAssistant = currentTurnEntries.last(where: { entry in
            entry.role == .assistant && entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }),
           let cleanedText = AssistantVisibleTextSanitizer.clean(latestAssistant.text) {
            return StreamPresentation(
                text: cleanedText,
                signaturePrefix: "assistant:\(latestAssistant.id.uuidString):\(latestAssistant.isStreaming)",
                allowsOverflow: !latestAssistant.isStreaming && !snapshot.hasActiveTurn
            )
        }

        if let latestError = currentTurnEntries.last(where: { entry in
            entry.role == .error && entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }),
           let cleanedText = AssistantVisibleTextSanitizer.clean(latestError.text) {
            return StreamPresentation(
                text: cleanedText,
                signaturePrefix: "error:\(latestError.id.uuidString)",
                allowsOverflow: true
            )
        }

        return nil
    }

    static func permissionText(_ request: AssistantPermissionRequest) -> String {
        if request.hasStructuredUserInput {
            return """
            Open Assist needs your answer to continue.

            \(request.toolTitle)
            """
        }

        if let rationale = request.rationale?.trimmingCharacters(in: .whitespacesAndNewlines), !rationale.isEmpty {
            return """
            Approval needed:
            \(request.toolTitle)

            \(rationale)
            """
        }

        return """
        Approval needed:
        \(request.toolTitle)
        """
    }

    static func closedSessionText() -> String {
        "Session view closed."
    }

    static func telegramPlainText(_ rawValue: String?) -> String? {
        let blocks = renderedBlocks(from: rawValue)
        guard !blocks.isEmpty else { return nil }

        let plainText = blocks
            .map(\.plainText)
            .joined(separator: "\n\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return plainText.isEmpty ? nil : plainText
    }

    private static func collapsed(_ text: String, maxLength: Int) -> String {
        let collapsed = (telegramPlainText(text) ?? text)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > maxLength else {
            return collapsed
        }
        return String(collapsed.prefix(max(0, maxLength - 1))) + "…"
    }

    private static func roleLabel(for role: AssistantTranscriptRole) -> String {
        switch role {
        case .system:
            return "System"
        case .user:
            return "You"
        case .assistant:
            return "Assistant"
        case .status:
            return "Status"
        case .tool:
            return "Tool"
        case .permission:
            return "Approval"
        case .error:
            return "Error"
        }
    }

    private static func renderedBlocks(from rawValue: String?) -> [RenderedBlock] {
        guard let text = AssistantVisibleTextSanitizer.clean(rawValue)?
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return []
        }

        var blocks: [RenderedBlock] = []
        for segment in AssistantMarkdownSegment.parse(from: text) {
            switch segment.kind {
            case .markdown(let markdown):
                blocks.append(contentsOf: renderMarkdownBlocks(markdown))
            case .codeBlock(let language, let code):
                blocks.append(makeCodeBlock(code: code, language: language))
            }
        }

        return blocks.filter { !$0.html.isEmpty && !$0.plainText.isEmpty }
    }

    private static func renderMarkdownBlocks(_ markdown: String) -> [RenderedBlock] {
        let lines = markdown.components(separatedBy: "\n")
        var blocks: [RenderedBlock] = []
        var paragraphLines: [String] = []
        var quoteLines: [String] = []
        var listItems: [TelegramListItem] = []
        var index = 0

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            let paragraphText = paragraphLines.joined(separator: " ")
            let rendered = renderInline(paragraphText)
            blocks.append(
                RenderedBlock(
                    html: rendered.html,
                    plainText: rendered.plainText,
                    kind: .richText
                )
            )
            paragraphLines.removeAll(keepingCapacity: true)
        }

        func flushQuote() {
            guard !quoteLines.isEmpty else { return }
            let quoteText = quoteLines.joined(separator: "\n")
            let rendered = renderInline(quoteText)
            blocks.append(
                RenderedBlock(
                    html: "<blockquote>\(rendered.html)</blockquote>",
                    plainText: rendered.plainText,
                    kind: .richText
                )
            )
            quoteLines.removeAll(keepingCapacity: true)
        }

        func flushList() {
            guard !listItems.isEmpty else { return }

            var indentationStack: [Int] = []
            var nextOrderedNumberByLevel: [Int: Int] = [:]
            var htmlLines: [String] = []
            var plainLines: [String] = []

            for item in listItems {
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

                let indent = String(repeating: "  ", count: nestingLevel)
                let rendered = renderInline(item.text)
                htmlLines.append("\(escapeHTML(indent + prefix))\(rendered.html)")
                plainLines.append("\(indent)\(prefix)\(rendered.plainText)")
            }

            blocks.append(
                RenderedBlock(
                    html: htmlLines.joined(separator: "\n"),
                    plainText: plainLines.joined(separator: "\n"),
                    kind: .richText
                )
            )
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
                let tableText = tableLines.joined(separator: "\n")
                blocks.append(makeCodeBlock(code: tableText, language: nil))
                index += tableLines.count
                continue
            }

            if looksLikeRawHTML(trimmed) {
                flushParagraph()
                flushQuote()
                flushList()
                blocks.append(makeCodeBlock(code: trimmed, language: nil))
                index += 1
                continue
            }

            if isHorizontalRule(trimmed) {
                flushParagraph()
                flushQuote()
                flushList()
                blocks.append(
                    RenderedBlock(
                        html: escapeHTML("──────────"),
                        plainText: "──────────",
                        kind: .richText
                    )
                )
                index += 1
                continue
            }

            if let heading = parseHeading(trimmed) {
                flushParagraph()
                flushQuote()
                flushList()
                let rendered = renderInline(heading.text)
                blocks.append(
                    RenderedBlock(
                        html: "<b>\(rendered.html)</b>",
                        plainText: rendered.plainText,
                        kind: .richText
                    )
                )
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

        return blocks
    }

    private static func renderInline(_ text: String) -> InlineRendering {
        var html = ""
        var plain = ""
        var index = text.startIndex

        while index < text.endIndex {
            if text[index...].hasPrefix("`"),
               let closingIndex = text[text.index(after: index)...].firstIndex(of: "`") {
                let codeText = String(text[text.index(after: index)..<closingIndex])
                html += "<code>\(escapeHTML(codeText))</code>"
                plain += codeText
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
                let urlText = String(text[urlRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                let labelRendering = renderInline(labelText)

                if isClickableURL(urlText) {
                    html += "<a href=\"\(escapeHTMLAttribute(urlText))\">\(labelRendering.html)</a>"
                    plain += labelRendering.plainText
                } else {
                    let fallbackText = "\(labelRendering.plainText) (\(urlText))"
                    html += "\(labelRendering.html) (\(escapeHTML(urlText)))"
                    plain += fallbackText
                }

                index = text.index(after: closingParen)
                continue
            }

            if text[index...].hasPrefix("**"),
               let closingRange = findClosingMarker("**", in: text, from: index) {
                let innerText = String(text[text.index(index, offsetBy: 2)..<closingRange.lowerBound])
                let inner = renderInline(innerText)
                html += "<b>\(inner.html)</b>"
                plain += inner.plainText
                index = closingRange.upperBound
                continue
            }

            if text[index...].hasPrefix("__"),
               let closingRange = findClosingMarker("__", in: text, from: index) {
                let innerText = String(text[text.index(index, offsetBy: 2)..<closingRange.lowerBound])
                let inner = renderInline(innerText)
                html += "<b>\(inner.html)</b>"
                plain += inner.plainText
                index = closingRange.upperBound
                continue
            }

            if text[index...].hasPrefix("~~"),
               let closingRange = findClosingMarker("~~", in: text, from: index) {
                let innerText = String(text[text.index(index, offsetBy: 2)..<closingRange.lowerBound])
                let inner = renderInline(innerText)
                html += "<s>\(inner.html)</s>"
                plain += inner.plainText
                index = closingRange.upperBound
                continue
            }

            if text[index] == "*",
               let closingRange = findClosingMarker("*", in: text, from: index) {
                let innerText = String(text[text.index(after: index)..<closingRange.lowerBound])
                let inner = renderInline(innerText)
                html += "<i>\(inner.html)</i>"
                plain += inner.plainText
                index = closingRange.upperBound
                continue
            }

            if text[index] == "_",
               let closingRange = findClosingMarker("_", in: text, from: index) {
                let innerText = String(text[text.index(after: index)..<closingRange.lowerBound])
                let inner = renderInline(innerText)
                html += "<i>\(inner.html)</i>"
                plain += inner.plainText
                index = closingRange.upperBound
                continue
            }

            let nextIndex = nextSpecialMarkerIndex(in: text, from: index) ?? text.endIndex
            if nextIndex == index {
                html += escapeHTML(String(text[index]))
                plain.append(text[index])
                index = text.index(after: index)
                continue
            }

            let chunk = String(text[index..<nextIndex])
            html += escapeHTML(chunk)
            plain += chunk
            index = nextIndex
        }

        return InlineRendering(
            html: html.trimmingCharacters(in: .whitespacesAndNewlines),
            plainText: plain.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func packBlocks(
        _ blocks: [RenderedBlock],
        limit: Int
    ) -> [TelegramRenderedText] {
        let separator = "\n\n"
        var packed: [TelegramRenderedText] = []
        var currentBlocks: [RenderedBlock] = []
        var currentHTML = ""
        var currentPlain = ""

        func flushCurrent() {
            let html = currentHTML.trimmingCharacters(in: .whitespacesAndNewlines)
            let plain = currentPlain.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !html.isEmpty, !plain.isEmpty else {
                currentBlocks = []
                currentHTML = ""
                currentPlain = ""
                return
            }
            packed.append(TelegramRenderedText(html: html, plainText: plain))
            currentBlocks = []
            currentHTML = ""
            currentPlain = ""
        }

        for originalBlock in blocks {
            let candidateBlocks = renderedLength(of: originalBlock) > limit
                ? splitBlockIfNeeded(originalBlock, limit: limit)
                : [originalBlock]

            for block in candidateBlocks where !block.html.isEmpty && !block.plainText.isEmpty {
                if currentBlocks.isEmpty {
                    currentBlocks = [block]
                    currentHTML = block.html
                    currentPlain = block.plainText
                    continue
                }

                let joinedHTML = currentHTML + separator + block.html
                let joinedPlain = currentPlain + separator + block.plainText
                if max(joinedHTML.count, joinedPlain.count) <= limit {
                    currentBlocks.append(block)
                    currentHTML = joinedHTML
                    currentPlain = joinedPlain
                    continue
                }

                flushCurrent()
                currentBlocks = [block]
                currentHTML = block.html
                currentPlain = block.plainText
            }
        }

        flushCurrent()
        return packed
    }

    private static func splitBlockIfNeeded(
        _ block: RenderedBlock,
        limit: Int
    ) -> [RenderedBlock] {
        guard renderedLength(of: block) > limit else {
            return [block]
        }

        switch block.kind {
        case .code(let language):
            return splitCodeBlock(block.plainText, language: language, limit: limit)
        case .richText:
            return chunkText(block.plainText, limit: max(1, limit - 16)).map { chunk in
                RenderedBlock(
                    html: escapeHTML(chunk),
                    plainText: chunk,
                    kind: .richText
                )
            }
        }
    }

    private static func splitCodeBlock(
        _ code: String,
        language: String?,
        limit: Int
    ) -> [RenderedBlock] {
        let safeLanguage = sanitizedLanguage(language)
        let wrapperOverhead: Int
        if let safeLanguage {
            wrapperOverhead = "<pre><code class=\"language-\(safeLanguage)\"></code></pre>".count
        } else {
            wrapperOverhead = "<pre></pre>".count
        }
        let effectiveLimit = max(1, limit - wrapperOverhead)

        var chunks: [String] = []
        var current = ""

        func flushCurrent() {
            let trimmed = current.trimmingCharacters(in: .newlines)
            guard !trimmed.isEmpty else {
                current = ""
                return
            }
            chunks.append(trimmed)
            current = ""
        }

        for rawLine in code.components(separatedBy: "\n") {
            let line = rawLine
            let candidate = current.isEmpty ? line : current + "\n" + line
            if candidate.count <= effectiveLimit {
                current = candidate
                continue
            }

            flushCurrent()

            if line.count <= effectiveLimit {
                current = line
                continue
            }

            let pieces = chunkText(line, limit: effectiveLimit)
            if pieces.isEmpty {
                continue
            }
            chunks.append(contentsOf: pieces)
        }

        flushCurrent()

        return chunks.map { makeCodeBlock(code: $0, language: language) }
    }

    private static func makeCodeBlock(code: String, language: String?) -> RenderedBlock {
        let safeCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeLanguage = sanitizedLanguage(language)
        if let safeLanguage {
            return RenderedBlock(
                html: "<pre><code class=\"language-\(safeLanguage)\">\(escapeHTML(safeCode))</code></pre>",
                plainText: safeCode,
                kind: .code(language: safeLanguage)
            )
        }

        return RenderedBlock(
            html: "<pre>\(escapeHTML(safeCode))</pre>",
            plainText: safeCode,
            kind: .code(language: nil)
        )
    }

    private static func renderedLength(of block: RenderedBlock) -> Int {
        max(block.html.count, block.plainText.count)
    }

    private static func nextSpecialMarkerIndex(
        in text: String,
        from index: String.Index
    ) -> String.Index? {
        text[index...].firstIndex(where: { character in
            character == "`" || character == "[" || character == "*" || character == "_" || character == "~"
        })
    }

    private static func findClosingMarker(
        _ marker: String,
        in text: String,
        from startIndex: String.Index
    ) -> Range<String.Index>? {
        let searchStart = text.index(startIndex, offsetBy: marker.count)
        guard searchStart <= text.endIndex else { return nil }
        return text[searchStart...].range(of: marker)
    }

    private static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func escapeHTMLAttribute(_ value: String) -> String {
        escapeHTML(value)
    }

    private static func isClickableURL(_ value: String) -> Bool {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased() else {
            return false
        }
        return scheme == "http" || scheme == "https" || scheme == "tg"
    }

    private static func sanitizedLanguage(_ language: String?) -> String? {
        guard let language = language?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !language.isEmpty else {
            return nil
        }

        let filtered = language.filter { character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
        }
        return filtered.isEmpty ? nil : filtered
    }

    private static func isHorizontalRule(_ line: String) -> Bool {
        let stripped = line.replacingOccurrences(of: " ", with: "")
        guard stripped.count >= 3 else { return false }
        let allDashes = stripped.allSatisfy { $0 == "-" }
        let allStars = stripped.allSatisfy { $0 == "*" }
        let allUnderscores = stripped.allSatisfy { $0 == "_" }
        return allDashes || allStars || allUnderscores
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

    private static func parseListItem(_ line: String) -> TelegramListItem? {
        let indentWidth = leadingIndentWidth(in: line)
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            return TelegramListItem(
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
              !components[1].trimmingCharacters(in: .whitespaces).isEmpty else {
            return nil
        }

        return TelegramListItem(
            style: .ordered(start: number),
            text: components[1].trimmingCharacters(in: .whitespaces),
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
