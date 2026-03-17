import AppKit
import MarkdownUI
import SwiftUI

struct AssistantMemorySuggestionReviewSheet: View {
    @ObservedObject var assistant: AssistantStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Memory Suggestions")
                        .font(.system(size: 18, weight: .bold))
                    Text("Review these lessons before they become long-term assistant memory.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.bordered)
            }

            if assistant.pendingMemorySuggestions.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("No memory suggestions waiting for review.")
                        .font(.system(size: 13, weight: .semibold))
                    Text("When the assistant finds a useful rule or a repeated mistake, it will show up here for review.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(assistant.pendingMemorySuggestions) { suggestion in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(alignment: .top, spacing: 8) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(suggestion.title)
                                            .font(.system(size: 14, weight: .semibold))
                                        Text(suggestion.kind.label)
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(suggestion.memoryType.label)
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(AppVisualTheme.accentTint)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(
                                            Capsule(style: .continuous)
                                                .fill(AppVisualTheme.accentTint.opacity(0.12))
                                        )
                                }

                                Text(suggestion.summary)
                                    .font(.system(size: 13, weight: .medium))

                                Text(suggestion.detail)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)

                                if let sourceExcerpt = suggestion.sourceExcerpt?.trimmingCharacters(in: .whitespacesAndNewlines),
                                   !sourceExcerpt.isEmpty {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("Source")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                        Text(sourceExcerpt)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(Color.white.opacity(0.04))
                                    )
                                }

                                HStack(spacing: 8) {
                                    Button("Ignore") {
                                        let shouldClose = assistant.pendingMemorySuggestions.count == 1
                                        assistant.ignoreMemorySuggestion(suggestion)
                                        if shouldClose {
                                            dismiss()
                                        }
                                    }
                                    .buttonStyle(.bordered)

                                    Button("Save Lesson") {
                                        let shouldClose = assistant.pendingMemorySuggestions.count == 1
                                        assistant.acceptMemorySuggestion(suggestion)
                                        if shouldClose {
                                            dismiss()
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                            }
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color.white.opacity(0.05))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .stroke(Color.white.opacity(0.08), lineWidth: 0.7)
                                    )
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 420)
        .background(AppChromeBackground())
    }
}

struct AssistantSessionRow: View {
    let session: AssistantSessionSummary
    let isSelected: Bool

    private var relativeTimestamp: String? {
        guard let updatedAt = session.updatedAt ?? session.createdAt else { return nil }
        let seconds = max(0, Int(Date().timeIntervalSince(updatedAt)))

        switch seconds {
        case 0..<60:
            return "now"
        case 60..<(60 * 60):
            return "\(max(1, seconds / 60))m"
        case (60 * 60)..<(60 * 60 * 24):
            return "\(max(1, seconds / (60 * 60)))h"
        case (60 * 60 * 24)..<(60 * 60 * 24 * 7):
            return "\(max(1, seconds / (60 * 60 * 24)))d"
        case (60 * 60 * 24 * 7)..<(60 * 60 * 24 * 30):
            return "\(max(1, seconds / (60 * 60 * 24 * 7)))w"
        default:
            let months = seconds / (60 * 60 * 24 * 30)
            return months >= 1 ? "\(months)mo" : {
                let formatter = DateFormatter()
                formatter.dateFormat = "MMM d"
                return formatter.string(from: updatedAt)
            }()
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(session.title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .white.opacity(0.96) : .white.opacity(0.78))
                .lineLimit(1)

            Spacer(minLength: 4)

            if let relativeTimestamp {
                Text(relativeTimestamp)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.white.opacity(isSelected ? 0.44 : 0.30))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.08) : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}


struct AssistantStatusBadge: View {
    let title: String
    let tint: Color
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(tint.opacity(0.95))
            }

            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.86))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(AssistantWindowChrome.buttonFill)
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(AssistantWindowChrome.border, lineWidth: 0.55)
                )
        )
    }
}

struct AssistantTopBarActionButton: View {
    let title: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
            Text(title)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(tint.opacity(0.94))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.08))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: 0.6)
                )
        )
    }
}

struct AssistantChatBubble: View {
    let message: AssistantChatMessage

    private var isUser: Bool { message.role == .user }

    var body: some View {
        if isUser {
            userBubble
        } else {
            assistantRow
        }
    }

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 80)

            VStack(alignment: .trailing, spacing: 4) {
                Text(message.text)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(Color(red: 0.15, green: 0.15, blue: 0.15))
                    )
                    .textSelection(.enabled)

                Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.3))
                    .padding(.trailing, 4)
            }
        }
        .padding(.vertical, 8)
    }

    private var assistantRow: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: roleIcon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(message.tint)
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(message.tint.opacity(0.15))
                )

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(message.roleLabel)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))

                    Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                }

                AssistantMarkdownText(text: message.text, role: message.role, isStreaming: message.isStreaming)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 24)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.clear)
        .padding(.trailing, 40)
    }

    private var roleIcon: String {
        switch message.role {
        case .assistant: return "sparkles"
        case .error: return "exclamationmark.triangle.fill"
        case .permission: return "lock.shield.fill"
        case .system: return "server.rack"
        default: return "bubble.left.fill"
        }
    }
}

struct AssistantMarkdownText: View {
    let text: String
    let role: AssistantTranscriptRole
    var isStreaming: Bool = false
    @AppStorage("assistantChatTextScale") private var textScale: Double = 1.0

    private func scaled(_ size: CGFloat) -> CGFloat {
        size * CGFloat(textScale)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            renderedText
            if isStreaming {
                StreamingCursor()
            }
        }
    }

    @ViewBuilder
    private var renderedText: some View {
        switch AssistantTextRenderingPolicy.style(for: text, isStreaming: isStreaming) {
        case .plain:
            Text(verbatim: text)
                .font(.system(size: scaled(14), weight: .regular))
                .foregroundStyle(.white.opacity(0.94))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .markdown:
            AssistantMarkdownSegmentsView(
                text: text,
                theme: assistantTheme,
                openURLAction: markdownOpenURLAction,
                codeFontSize: scaled(13)
            )
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var markdownOpenURLAction: OpenURLAction {
        OpenURLAction { url in
            let scheme = url.scheme?.lowercased() ?? ""

            // Allow normal web links
            if scheme == "http" || scheme == "https" {
                NSWorkspace.shared.open(url)
                return .handled
            }

            // Try opening file-like paths in VS Code if installed
            let path = url.path
            if scheme == "file" || scheme.isEmpty,
               !path.isEmpty {
                let vscodeURL = URL(string: "vscode://file\(path)")
                if let vscodeURL,
                   NSWorkspace.shared.urlForApplication(toOpen: vscodeURL) != nil {
                    NSWorkspace.shared.open(vscodeURL)
                    return .handled
                }
            }

            return .discarded
        }
    }

    private var assistantTheme: MarkdownUI.Theme {
        .init()
            .text {
                ForegroundColor(.white.opacity(0.95))
                FontSize(scaled(14))
            }
            .heading1 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontSize(self.scaled(19))
                        FontWeight(.bold)
                        ForegroundColor(.white.opacity(0.96))
                    }
                    .markdownMargin(top: 16, bottom: 10)
            }
            .heading2 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontSize(self.scaled(17))
                        FontWeight(.bold)
                        ForegroundColor(.white.opacity(0.94))
                    }
                    .markdownMargin(top: 14, bottom: 8)
            }
            .heading3 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontSize(self.scaled(15))
                        FontWeight(.semibold)
                        ForegroundColor(.white.opacity(0.92))
                    }
                    .markdownMargin(top: 10, bottom: 6)
            }
            .strong {
                FontWeight(.bold)
                ForegroundColor(.white.opacity(0.96))
            }
            .emphasis {
                FontStyle(.italic)
                ForegroundColor(.white.opacity(0.85))
            }
            .link {
                ForegroundColor(AppVisualTheme.accentTint)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(scaled(13))
                ForegroundColor(Color(red: 0.75, green: 0.85, blue: 1.0))
                BackgroundColor(Color(red: 0.12, green: 0.13, blue: 0.18))
            }
            .codeBlock { configuration in
                ScrollView(.horizontal, showsIndicators: true) {
                    configuration.label
                        .markdownTextStyle {
                            FontFamilyVariant(.monospaced)
                            FontSize(self.scaled(13))
                            ForegroundColor(.white.opacity(0.85))
                        }
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(red: 0.05, green: 0.05, blue: 0.07))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                        )
                )
                .markdownMargin(top: 8, bottom: 8)
            }
            .blockquote { configuration in
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(AppVisualTheme.accentTint.opacity(0.5))
                        .frame(width: 3)
                    configuration.label
                        .markdownTextStyle {
                            ForegroundColor(.white.opacity(0.72))
                            FontStyle(.italic)
                        }
                        .padding(.leading, 12)
                }
                .markdownMargin(top: 6, bottom: 6)
            }
            .listItem { configuration in
                configuration.label
                    .markdownMargin(top: 4, bottom: 4)
            }
            .paragraph { configuration in
                configuration.label
                    .markdownMargin(top: 0, bottom: 10)
            }
    }
}

struct StreamingCursor: View {
    @State private var visible = true

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.white.opacity(visible ? 0.7 : 0.0))
            .frame(width: 2, height: 16)
            .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: visible)
            .onAppear { visible = false }
    }
}

struct AssistantMarkdownSegmentsView: View {
    let text: String
    let theme: MarkdownUI.Theme
    let openURLAction: OpenURLAction
    let codeFontSize: CGFloat

    private var segments: [AssistantMarkdownSegment] {
        AssistantMarkdownSegment.parse(from: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(segments) { segment in
                segmentView(segment)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func segmentView(_ segment: AssistantMarkdownSegment) -> some View {
        switch segment.kind {
        case .markdown(let markdown):
            Markdown(markdown)
                .markdownTheme(theme)
                .markdownCodeSyntaxHighlighter(.plainText)
                .environment(\.openURL, openURLAction)
        case .codeBlock(let language, let code):
            codeBlockView(language: language, code: code)
        }
    }

    private func codeBlockView(language: String?, code: String) -> some View {
        VStack(alignment: .leading, spacing: language == nil ? 0 : 8) {
            if let language = language?.trimmingCharacters(in: .whitespacesAndNewlines).assistantNonEmpty {
                Text(language.uppercased())
                    .font(.system(size: max(10, codeFontSize - 2), weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.42))
                    .textSelection(.enabled)
            }

            ScrollView(.horizontal, showsIndicators: true) {
                Text(verbatim: code)
                    .font(.system(size: codeFontSize, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(red: 0.05, green: 0.05, blue: 0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                )
        )
    }
}

// MARK: - Session Instructions Popover

struct SessionInstructionsPopover: View {
    @Binding var instructions: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "text.quote")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Session Instructions")
                    .font(.system(size: 13, weight: .semibold))
            }

            Text("These instructions apply only to this session. They are combined with your global instructions from Settings.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $instructions)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 80, maxHeight: 140)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(.textBackgroundColor).opacity(0.5))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.8)
                        )
                )

            if !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.green)
                        .font(.system(size: 11))
                    Text("Active for this session")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") {
                        instructions = ""
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}

@MainActor
struct AssistantChatMessage: Identifiable {
    let id: UUID
    let role: AssistantTranscriptRole
    let text: String
    let timestamp: Date
    let emphasis: Bool
    let isStreaming: Bool

    var roleLabel: String {
        switch role {
        case .assistant: return "Assistant"
        case .user: return "You"
        case .permission: return "Permission"
        case .error: return "Error"
        case .status: return "Status"
        case .system: return "System"
        case .tool: return "Tool"
        }
    }

    var tint: Color {
        switch role {
        case .assistant:
            return AppVisualTheme.accentTint
        case .user:
            return AppVisualTheme.baseTint
        case .permission:
            return .orange
        case .error:
            return .red
        case .status, .system, .tool:
            return Color(red: 0.42, green: 0.76, blue: 0.95)
        }
    }

    var alignment: HorizontalAlignment {
        switch role {
        case .user:
            return .trailing
        default:
            return .leading
        }
    }

    var fillOpacity: Double {
        switch role {
        case .user:
            return 0.16
        case .assistant:
            return 0.11
        case .error:
            return 0.13
        default:
            return 0.09
        }
    }

    var strokeOpacity: Double {
        emphasis ? 0.34 : 0.22
    }

    static func grouped(from entries: [AssistantTranscriptEntry]) -> [AssistantChatMessage] {
        entries.compactMap { entry in
            guard let text = entry.text.assistantNonEmpty else { return nil }
            return AssistantChatMessage(
                id: entry.id,
                role: entry.role,
                text: text,
                timestamp: entry.createdAt,
                emphasis: entry.emphasis,
                isStreaming: entry.isStreaming
            )
        }
    }
}

enum AssistantTextRenderingStyle {
    case plain
    case markdown
}

enum AssistantTextRenderingPolicy {
    static func style(for text: String, isStreaming: Bool) -> AssistantTextRenderingStyle {
        if isStreaming {
            return .plain
        }

        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        if normalized.contains("```") || normalized.contains("`") {
            return .markdown
        }

        if normalized.range(of: #"\[[^\]]+\]\([^)]+\)"#, options: .regularExpression) != nil {
            return .markdown
        }

        if normalized.range(of: #"(^|[\s])(\*\*|__|~~)[^\n]+(\*\*|__|~~)(?=$|[\s])"#, options: [.regularExpression]) != nil {
            return .markdown
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#")
                || line.hasPrefix("> ")
                || line.hasPrefix("- ")
                || line.hasPrefix("* ")
                || line.hasPrefix("+ ")
                || line.hasPrefix("|") {
                return .markdown
            }

            if line.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil {
                return .markdown
            }
        }

        return .plain
    }
}

enum AssistantVisibleTextSanitizer {
    static func clean(_ rawValue: String?) -> String? {
        guard var text = rawValue?.replacingOccurrences(of: "\r\n", with: "\n").assistantNonEmpty else {
            return nil
        }

        text = removingAnalysisBlocks(from: text)

        if let closingRange = text.range(of: "</analysis>", options: [.caseInsensitive]) {
            let prefix = text[..<closingRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = text[closingRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            text = preferredVisibleSlice(prefix: String(prefix), suffix: String(suffix))
        }

        if let openingRange = text.range(of: "<analysis>", options: [.caseInsensitive]) {
            text = String(text[..<openingRange.lowerBound])
        }

        text = text
            .removingAssistantAttachmentPlaceholders()
            .replacingOccurrences(of: "<analysis>", with: "", options: [.caseInsensitive])
            .replacingOccurrences(of: "</analysis>", with: "", options: [.caseInsensitive])
            .replacingOccurrences(of: "<proposed_plan>", with: "", options: [.caseInsensitive])
            .replacingOccurrences(of: "</proposed_plan>", with: "", options: [.caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return text.assistantNonEmpty
    }

    private static func removingAnalysisBlocks(from text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"<analysis\b[^>]*>[\s\S]*?</analysis>"#,
            options: [.caseInsensitive]
        ) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func preferredVisibleSlice(prefix: String, suffix: String) -> String {
        let normalizedPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSuffix = suffix.trimmingCharacters(in: .whitespacesAndNewlines)

        if looksLikeInternalScratchpad(normalizedSuffix), !normalizedPrefix.isEmpty {
            return normalizedPrefix
        }

        if !normalizedSuffix.isEmpty && normalizedPrefix.isEmpty {
            return normalizedSuffix
        }

        if !normalizedPrefix.isEmpty {
            return normalizedPrefix
        }

        return normalizedSuffix
    }

    private static func looksLikeInternalScratchpad(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let markers = [
            "need ",
            "let's ",
            "wait:",
            "maybe ",
            "we should ",
            "i should ",
            "final answer",
            "output final",
            "plan-only",
            "ensure "
        ]
        return markers.contains(where: lowered.contains)
    }
}

struct AssistantMarkdownSegment: Identifiable {
    enum Kind {
        case markdown(String)
        case codeBlock(language: String?, code: String)
    }

    let id: Int
    let kind: Kind

    static func parse(from text: String) -> [AssistantMarkdownSegment] {
        var segments: [AssistantMarkdownSegment] = []
        var currentMarkdown: [String] = []
        var insideCodeBlock = false
        var codeLanguage: String?
        var codeLines: [String] = []
        var nextIndex = 0

        func flushMarkdown() {
            let value = currentMarkdown.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                segments.append(AssistantMarkdownSegment(id: nextIndex, kind: .markdown(value)))
                nextIndex += 1
            }
            currentMarkdown.removeAll()
        }

        func flushCodeBlock() {
            let value = codeLines.joined(separator: "\n")
            if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segments.append(AssistantMarkdownSegment(id: nextIndex, kind: .codeBlock(language: codeLanguage, code: value)))
                nextIndex += 1
            }
            codeLines.removeAll()
            codeLanguage = nil
        }

        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                if insideCodeBlock {
                    flushCodeBlock()
                    insideCodeBlock = false
                } else {
                    flushMarkdown()
                    insideCodeBlock = true
                    let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                    codeLanguage = language.isEmpty ? nil : language
                }
                continue
            }

            if insideCodeBlock {
                codeLines.append(line)
            } else {
                currentMarkdown.append(line)
            }
        }

        if insideCodeBlock {
            flushCodeBlock()
        } else {
            flushMarkdown()
        }

        if segments.isEmpty {
            let fallback = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !fallback.isEmpty {
                segments.append(AssistantMarkdownSegment(id: 0, kind: .markdown(fallback)))
            }
        }

        return segments
    }
}

struct ChatScrollInteractionMonitor: NSViewRepresentable {
    let onUserScroll: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onUserScroll: onUserScroll)
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onUserScroll = onUserScroll

        DispatchQueue.main.async {
            guard let hostView = nsView.superview else { return }
            context.coordinator.attachIfNeeded(to: hostView)
        }
    }

    final class Coordinator {
        var onUserScroll: () -> Void
        private weak var observedScrollView: NSScrollView?
        private var observers: [NSObjectProtocol] = []

        init(onUserScroll: @escaping () -> Void) {
            self.onUserScroll = onUserScroll
        }

        deinit {
            removeObservers()
        }

        func attachIfNeeded(to hostView: NSView) {
            guard let scrollView = findScrollView(in: hostView) else { return }
            guard observedScrollView !== scrollView else { return }

            removeObservers()
            observedScrollView = scrollView

            let center = NotificationCenter.default
            observers.append(
                center.addObserver(
                    forName: NSScrollView.willStartLiveScrollNotification,
                    object: scrollView,
                    queue: .main
                ) { [weak self] _ in
                    self?.onUserScroll()
                }
            )
            observers.append(
                center.addObserver(
                    forName: NSScrollView.didLiveScrollNotification,
                    object: scrollView,
                    queue: .main
                ) { [weak self] _ in
                    self?.onUserScroll()
                }
            )
        }

        private func removeObservers() {
            let center = NotificationCenter.default
            observers.forEach(center.removeObserver)
            observers.removeAll()
            observedScrollView = nil
        }

        private func findScrollView(in view: NSView) -> NSScrollView? {
            if let scrollView = view as? NSScrollView {
                return scrollView
            }

            for subview in view.subviews {
                if let scrollView = findScrollView(in: subview) {
                    return scrollView
                }
            }

            return nil
        }
    }
}

// MARK: - Composer Text View (Enter to send, Shift+Enter for newline)

struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    var isEnabled: Bool = true
    var onSubmit: () -> Void
    var onToggleMode: (() -> Void)?
    var onPasteAttachment: ((AssistantAttachment) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = SubmittableTextView()
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 14, weight: .regular)
        textView.textColor = NSColor.white.withAlphaComponent(0.92)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(
            width: assistantComposerTextHorizontalInset,
            height: assistantComposerTextVerticalInset
        )
        textView.textContainer?.lineFragmentPadding = assistantComposerLineFragmentPadding
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = context.coordinator
        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled
        textView.onSubmit = onSubmit
        textView.onToggleMode = onToggleMode
        textView.onPasteAttachment = onPasteAttachment
        AssistantComposerBridge.shared.register(textView: textView, target: .assistantWindow)

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        AssistantComposerBridge.shared.register(textView: textView, target: .assistantWindow)
        if textView.string != text {
            let selectedRanges = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selectedRanges
        }
        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled
        if let textView = textView as? SubmittableTextView {
            textView.onSubmit = onSubmit
            textView.onToggleMode = onToggleMode
            textView.onPasteAttachment = onPasteAttachment
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: ComposerTextView
        init(parent: ComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

final class SubmittableTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onToggleMode: (() -> Void)?
    var onPasteAttachment: ((AssistantAttachment) -> Void)?

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
    }
}

// MARK: - Context Usage Bar

struct ContextUsageBar: View {
    let fraction: Double

    private var barColor: Color {
        if fraction > 0.85 { return .red }
        if fraction > 0.65 { return .orange }
        return AppVisualTheme.accentTint
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.08))
                RoundedRectangle(cornerRadius: 2)
                    .fill(barColor.opacity(0.7))
                    .frame(width: geo.size.width * CGFloat(fraction))
            }
        }
    }
}

// MARK: - Context Usage Circle

struct ContextUsageCircle: View {
    let usage: TokenUsageSnapshot
    @State private var isHovering = false

    private var fraction: Double {
        usage.contextUsageFraction ?? 0
    }

    private var ringColor: Color {
        if fraction > 0.85 { return .red }
        if fraction > 0.65 { return .orange }
        return AppVisualTheme.accentTint
    }

    private var percentText: String {
        "\(Int(round(fraction * 100)))%"
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.08), lineWidth: 2)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(ringColor.opacity(0.8), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(percentText)
                .font(.system(size: 7, weight: .semibold, design: .monospaced))
                .foregroundStyle(ringColor.opacity(0.9))
        }
        .frame(width: 22, height: 22)
        .contentShape(Circle())
        .overlay(alignment: .topTrailing) {
            if isHovering {
                ContextUsageHoverCard(
                    title: usage.exactContextSummary,
                    detail: usage.contextTooltipDetail
                )
                .offset(x: -4, y: -52)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomTrailing)))
                .allowsHitTesting(false)
            }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                isHovering = hovering
            }
        }
        .zIndex(isHovering ? 10 : 0)
    }
}

private struct ContextUsageHoverCard: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white)
            Text(detail)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.74))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.black.opacity(0.94))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 0.7)
                )
        )
        .shadow(color: Color.black.opacity(0.28), radius: 16, x: 0, y: 8)
        .fixedSize()
    }
}

// MARK: - Rate Limits View

struct RateLimitsView: View {
    let limits: AccountRateLimits
    var isExpanded: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: isExpanded ? 4 : 2) {
            if let primary = limits.primary {
                rateLimitRow(window: primary, label: primary.windowLabel.isEmpty ? "Usage" : primary.windowLabel)
            }
            if let secondary = limits.secondary {
                rateLimitRow(window: secondary, label: secondary.windowLabel.isEmpty ? "Limit" : secondary.windowLabel)
            }
        }
    }

    private func rateLimitRow(window: RateLimitWindow, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.50))
                Spacer()
                Text("\(window.usedPercent)% used")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(window.usedPercent > 80 ? .red.opacity(0.8) : .white.opacity(0.45))
                if isExpanded, let resets = window.resetsInLabel {
                    Text("resets \(resets)")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.30))
                }
            }
            ContextUsageBar(fraction: Double(window.usedPercent) / 100.0)
                .frame(height: isExpanded ? 3 : 2)
        }
        .help(!isExpanded && window.resetsInLabel != nil ? "Resets \(window.resetsInLabel!)" : "")
    }
}

// MARK: - Subagent Strip

struct SubagentStrip: View {
    let subagents: [SubagentState]

    private var activeAgents: [SubagentState] {
        subagents.filter { $0.status.isActive }
    }

    private var completedCount: Int {
        subagents.filter { !$0.status.isActive }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "person.3.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.50))
                Text("\(activeAgents.count) active agent\(activeAgents.count == 1 ? "" : "s")")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.65))
                if completedCount > 0 {
                    Text("· \(completedCount) done")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.35))
                }
                Spacer()
            }

            ForEach(activeAgents) { agent in
                HStack(spacing: 6) {
                    Image(systemName: agent.status.icon)
                        .font(.system(size: 9))
                        .foregroundStyle(agentTint(agent.status))
                    Text(agent.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.70))
                    if let prompt = agent.prompt?.prefix(50), !prompt.isEmpty {
                        Text(String(prompt))
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.30))
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(agent.status.rawValue)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(agentTint(agent.status).opacity(0.7))
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
                )
        )
    }

    private func agentTint(_ status: SubagentStatus) -> Color {
        switch status {
        case .spawning, .running: return .blue
        case .waiting: return .orange
        case .completed: return .green
        case .errored: return .red
        case .closed: return .gray
        }
    }
}

// MARK: - Scroll tracking

struct ScrollTopOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct ScrollBottomOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct ScrollViewportHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
