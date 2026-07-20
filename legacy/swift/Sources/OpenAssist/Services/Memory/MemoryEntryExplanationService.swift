import Foundation
import Security
import Vision

enum MemoryEntryExplanationResult {
    case success(String)
    case failure(String)
}

struct SelectionAskConversationTurn: Equatable, Sendable {
    enum Role: String, Equatable, Sendable {
        case user
        case assistant

        var transcriptLabel: String {
            switch self {
            case .user:
                return "User"
            case .assistant:
                return "Assistant"
            }
        }
    }

    let role: Role
    let text: String

    init(role: Role, text: String) {
        self.role = role
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct SelectionAskPrompt: Equatable, Sendable {
    let systemPrompt: String
    let userPrompt: String
}

struct ThreadNoteChartPrompt: Equatable, Sendable {
    let systemPrompt: String
    let userPrompt: String
}

struct ThreadNoteOrganizePrompt: Equatable, Sendable {
    let systemPrompt: String
    let userPrompt: String
}

enum ThreadNoteScreenshotImportMode: String, Sendable {
    case rawOCR
    case cleanText
    case cleanTextAndImage
}

enum ThreadNoteScreenshotCaptureMode: String, Sendable {
    case area
    case scrolling
    case multiple
}

struct ThreadNoteScreenshotImportPreparation: Equatable, Sendable {
    let markdown: String
    let rawText: String
    let usedVision: Bool
}

enum ThreadNoteScreenshotImportPreparationResult {
    case success(ThreadNoteScreenshotImportPreparation)
    case failure(String)
}

struct BatchNotePlanPrompt: Equatable, Sendable {
    let systemPrompt: String
    let userPrompt: String
}

struct ProjectNoteTransferSuggestion: Equatable, Sendable {
    let headingPath: [String]?
    let insertedMarkdown: String
    let reason: String
}

enum ProjectNoteTransferSuggestionResult {
    case success(ProjectNoteTransferSuggestion)
    case failure(String)
}

enum BatchNotePlanPromptBuilder {
    static func makePrompt(
        sourceNotes: [AssistantBatchNotePlanSourceContext]
    ) -> BatchNotePlanPrompt {
        let sourceBlock = sourceNotes.enumerated().map { index, source in
            """
            Source \(index + 1)
            - ref: \(source.ref)
            - title: \(snippet(source.title, limit: 180))
            - type: \(source.noteType.rawValue)
            - source_label: \(snippet(source.sourceLabel, limit: 80))
            - markdown:
            \(indented(snippet(source.markdown, limit: 10_000)))
            """
        }
        .joined(separator: "\n\n")

        let systemPrompt = """
        You organize multiple notes into a clean note set for a non-technical user.
        Output JSON only.
        Do not wrap the JSON in markdown fences.
        Keep important facts, decisions, tasks, examples, filenames, commands, and constraints.
        Do not invent missing details.
        Create exactly one note with noteType "master".
        Allowed noteType values are: master, note, decision, task, reference, question.
        Each note must keep a readable markdown body.
        Do not include markdown links inside the note markdown. Return relationships through the links array instead.
        Only use source note refs that were provided.
        Only create links from a generated note to another generated note or to a provided source note.
        Use this JSON shape exactly:
        {
          "notes": [
            {
              "tempId": "master-overview",
              "title": "Project Master Note",
              "noteType": "master",
              "markdown": "# Summary\\n\\n...",
              "sourceNoteRefs": ["S1", "S2"]
            }
          ],
          "links": [
            {
              "fromTempId": "master-overview",
              "toTarget": {
                "kind": "proposed",
                "ref": "decision-auth"
              }
            },
            {
              "fromTempId": "decision-auth",
              "toTarget": {
                "kind": "source",
                "ref": "S2"
              }
            }
          ]
        }
        """

        let userPrompt = """
        Reorganize these source notes into a clean shared project note set.

        Goals:
        - Create a master note plus supporting notes.
        - Split content where it naturally belongs.
        - Preserve detail without repeating the same information too many times.
        - Use simple wording and clear headings.
        - Keep the notes grounded in the provided source notes.

        Source notes:
        \(sourceBlock)
        """

        return BatchNotePlanPrompt(systemPrompt: systemPrompt, userPrompt: userPrompt)
    }

    private static func snippet(_ value: String, limit: Int) -> String {
        let normalized = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(max(0, limit - 3))) + "..."
    }

    private static func indented(_ value: String) -> String {
        value
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "  \($0)" }
            .joined(separator: "\n")
    }
}

enum SelectionAskPromptBuilder {
    static func makePrompt(
        selectedText: String,
        parentMessageText: String,
        question: String? = nil,
        conversationHistory: [SelectionAskConversationTurn] = [],
        wholeChatSummary: String? = nil
    ) -> SelectionAskPrompt {
        let normalizedSelection = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedParentMessage = parentMessageText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedQuestion = question?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let normalizedWholeChatSummary = wholeChatSummary?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty

        if let normalizedQuestion {
            let shouldSuggestReplies = questionNeedsReplySuggestions(normalizedQuestion)
            let contextualParentMessage = focusedContextSnippet(
                parentMessage: normalizedParentMessage,
                selectedText: normalizedSelection,
                limit: 500
            ).nonEmpty
            let recentHistory = Array(
                conversationHistory
                    .filter { !$0.text.isEmpty }
                    .suffix(3)
            )

            let historySection: String
            if recentHistory.isEmpty {
                historySection = ""
            } else {
                let transcript = recentHistory
                    .map { "\($0.role.transcriptLabel): \(snippet($0.text, limit: 120))" }
                    .joined(separator: "\n")
                historySection = """

                Previous side-assistant conversation:
                \(transcript)
                """
            }

            let wholeChatSection: String
            if let normalizedWholeChatSummary {
                wholeChatSection = """

                Recent chat context:
                \(snippet(normalizedWholeChatSummary, limit: 600))
                """
            } else {
                wholeChatSection = ""
            }

            let parentMessageSection: String
            if let contextualParentMessage {
                parentMessageSection = """

                Nearby message context:
                \(contextualParentMessage)
                """
            } else {
                parentMessageSection = ""
            }

            return SelectionAskPrompt(
                systemPrompt: """
                You are a side assistant for an ongoing chat.
                Answer in a natural, conversational way for a non-technical user.
                Use easy words, short paragraphs, and keep it concise.
                Use the selected text, nearby message context, recent chat context, and previous side-assistant turns as helpful background.
                If the user asks what to say next, give concrete suggestions instead of repeating the text.
                \(shouldSuggestReplies
                    ? "End with a short section exactly titled \"You could reply:\" and give 2 or 3 short reply ideas."
                    : "Do not include a section titled \"You could reply:\" unless the user is clearly asking for wording, a reply, or a response to send.")
                Output plain text only.
                If you are not sure, say that plainly.
                """,
                userPrompt: """
                You are helping with this ongoing chat.

                Selected text:
                \(snippet(normalizedSelection, limit: 600))\(parentMessageSection)\(wholeChatSection)\(historySection)

                New question:
                \(normalizedQuestion)
                """
            )
        }

        return SelectionAskPrompt(
            systemPrompt: """
            You explain selected text in simple terms for a non-technical user.
            Output plain text only.
            Use short paragraphs and easy words.
            Stay faithful to the selected text.
            If the text uses jargon, explain it with simpler wording.
            """,
            userPrompt: """
            Explain this selected text in simple terms.

            Selected text:
            \(snippet(normalizedSelection, limit: 12_000))

            Full message context:
            \(snippet(normalizedParentMessage, limit: 18_000))
            """
        )
    }

    private static func snippet(_ value: String, limit: Int) -> String {
        let normalized = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(max(0, limit - 3))) + "..."
    }

    private static func focusedContextSnippet(
        parentMessage: String,
        selectedText: String,
        limit: Int
    ) -> String {
        let normalizedParent = parentMessage
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSelection = selectedText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedParent.isEmpty else { return "" }
        guard normalizedParent != normalizedSelection else { return "" }
        guard !normalizedSelection.isEmpty,
              let range = normalizedParent.range(of: normalizedSelection) else {
            return snippet(normalizedParent, limit: limit)
        }
        guard normalizedParent.count > limit else { return normalizedParent }
        guard normalizedSelection.count < limit else {
            return snippet(normalizedSelection, limit: limit)
        }

        let lowerDistance = normalizedParent.distance(from: normalizedParent.startIndex, to: range.lowerBound)
        let upperDistance = normalizedParent.distance(from: normalizedParent.startIndex, to: range.upperBound)
        let remainingBudget = max(0, limit - normalizedSelection.count)
        let prefixBudget = remainingBudget / 2
        let suffixBudget = remainingBudget - prefixBudget
        let startOffset = max(0, lowerDistance - prefixBudget)
        let endOffset = min(normalizedParent.count, upperDistance + suffixBudget)
        let startIndex = normalizedParent.index(normalizedParent.startIndex, offsetBy: startOffset)
        let endIndex = normalizedParent.index(normalizedParent.startIndex, offsetBy: endOffset)

        var focused = String(normalizedParent[startIndex..<endIndex])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if startOffset > 0 {
            focused = "..." + focused
        }
        if endOffset < normalizedParent.count {
            focused += "..."
        }
        return focused
    }

    private static func questionNeedsReplySuggestions(_ question: String) -> Bool {
        let normalized = question
            .lowercased()
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let replyIndicators = [
            "what should i say",
            "what do i say",
            "what can i say",
            "what could i say",
            "what should i send",
            "how should i say",
            "how do i say",
            "how should i answer",
            "how should i respond",
            "what should i reply",
            "say back",
            "reply back",
            "message back",
            "respond back",
            "draft a reply",
            "suggest a reply",
            "what to reply",
            "what to respond",
            "what to say next",
            "what should i tell",
            "word this",
            "write a response"
        ]

        return replyIndicators.contains { normalized.contains($0) }
    }
}

enum ThreadNoteChartPromptBuilder {
    static func makePrompt(
        selectedText: String,
        parentMessageText: String,
        currentDraft: String? = nil,
        styleInstruction: String? = nil,
        validationError: String? = nil
    ) -> ThreadNoteChartPrompt {
        let normalizedSelection = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedParentMessage = parentMessageText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCurrentDraft = currentDraft?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
        let normalizedStyleInstruction = styleInstruction?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
        let normalizedValidationError = validationError?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty

        let supportedTypes = """
        Supported Mermaid types:
        - flowchart
        - sequenceDiagram
        - classDiagram
        - stateDiagram-v2
        - erDiagram
        - journey
        - gantt
        - pie
        - gitGraph
        - mindmap
        - timeline
        - quadrantChart
        - architecture-beta
        - block-beta
        """

        let systemPrompt = """
        You turn selected note or chat content into a Mermaid chart for a non-technical user.
        Output markdown only.
        Return exactly:
        1. a short markdown heading
        2. one Mermaid fenced code block
        Do not include extra explanation before or after the chart.
        Do not output more than one Mermaid block.
        Keep node labels short, clear, and easy to scan.
        Prefer simple structure over dense detail.
        Prefer a presentation-ready diagram with a clear reading order.
        For flowcharts, default to a top-to-bottom layout unless another direction is clearly better.
        Use subgraphs or grouped stages when that makes the chart easier to scan.
        If the content is sequential, prefer a small number of main steps instead of many tiny nodes.
        Keep each node focused on one idea.
        If a node needs one short detail line, you may use <br/> for a second line.
        When color helps clarity, choose a small Mermaid color palette in the chart itself.
        For flowcharts, you may use classDef, class, style, or linkStyle to separate stages or systems.
        Keep the palette restrained, usually 2 to 4 colors.
        Use only supported Mermaid types.
        For hierarchy or stack breakdowns, prefer mindmap, block-beta, architecture-beta, or a grouped flowchart.
        For step-by-step processes, prefer flowchart or sequenceDiagram.
        For dated phases, prefer timeline or gantt.
        For data/entity relationships, prefer erDiagram or classDiagram.
        For flowcharts, if a subgraph label has spaces or punctuation, write it like subgraph Core["RAPID Core (shared)"].
        Do not write flowchart subgraph titles like subgraph Core[RAPID Core (shared)].
        Quote labels that contain punctuation such as parentheses, slashes, colons, or commas.
        For flowchart node labels, always use quoted labels when punctuation appears, for example A["Check stacks (matching app)"].
        Never write flowchart labels with raw parentheses inside square brackets, such as A[Check stacks (matching app)].
        Prefer short labels over copying long parenthetical details from the source text.
        Use ASCII characters only.
        If a current draft fails Mermaid rendering, fix the Mermaid syntax or unsupported constructs and return a corrected chart.
        Prefer valid Mermaid syntax and compatibility over decorative extras.

        \(supportedTypes)
        """

        let currentDraftSection = normalizedCurrentDraft.map {
            """

            Current chart draft:
            \(snippet($0, limit: 14_000))
            """
        } ?? ""

        let userPrompt: String
        if let normalizedValidationError {
            let styleSection = normalizedStyleInstruction.map {
                """

                Requested style or chart preference:
                \(snippet($0, limit: 1_200))
                """
            } ?? ""

            userPrompt = """
            Repair the Mermaid chart so it renders correctly.

            Selected text:
            \(snippet(normalizedSelection, limit: 10_000))

            Full message context:
            \(snippet(normalizedParentMessage, limit: 16_000))\(currentDraftSection)

            Mermaid render error:
            \(snippet(normalizedValidationError, limit: 1_600))\(styleSection)

            Keep the chart faithful to the source content. Preserve the intended chart type when possible, but change the syntax or structure if needed to return valid Mermaid.
            """
        } else if normalizedCurrentDraft != nil {
            let styleSection = normalizedStyleInstruction.map {
                """

                Change request:
                \(snippet($0, limit: 1_200))
                """
            } ?? ""

            userPrompt = """
            Regenerate the chart from this selected content.

            Selected text:
            \(snippet(normalizedSelection, limit: 10_000))

            Full message context:
            \(snippet(normalizedParentMessage, limit: 16_000))\(currentDraftSection)\(styleSection)

            Return a fresh Mermaid version that stays true to the source content and renders correctly.
            """
        } else {
            userPrompt = """
            Create the best Mermaid chart for this selected content.

            Selected text:
            \(snippet(normalizedSelection, limit: 10_000))

            Full message context:
            \(snippet(normalizedParentMessage, limit: 16_000))
            """
        }

        return ThreadNoteChartPrompt(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt
        )
    }

    private static func snippet(_ value: String, limit: Int) -> String {
        let normalized = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(max(0, limit - 3))) + "..."
    }
}

enum ThreadNoteOrganizePromptBuilder {
    static func makePrompt(
        noteText: String,
        selectedText: String? = nil,
        styleInstruction: String? = nil
    ) -> ThreadNoteOrganizePrompt {
        let normalizedNoteText = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSelectedText = selectedText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
        let normalizedStyleInstruction = styleInstruction?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
        let selectionMatchesWholeNote = normalizedSelectedText == normalizedNoteText

        let systemPrompt = """
        You organize thread notes for a non-technical user.
        Output markdown only.
        Use simple wording, clear headings, and readable bullet lists.
        Keep the original detail level unless the source is clearly repetitive or noisy.
        Preserve important facts, decisions, action items, constraints, examples, filenames, config names, commands, and environment names.
        If the source already has useful bullets or sections, keep that structure or improve it instead of flattening it.
        Do not compress many bullets or examples into one or two sentences.
        Merge duplicates when helpful, but do not drop unique details.
        Do not invent missing details.
        Do not wrap the whole answer in a code fence.
        """

        let userPrompt: String
        if let normalizedSelectedText {
            let noteContextSection: String
            if selectionMatchesWholeNote {
                noteContextSection = ""
            } else {
                noteContextSection = """

                Full note context (background only; use this to resolve references, but focus on organizing the selected content):
                \(snippet(normalizedNoteText, limit: 14_000))
                """
            }

            userPrompt = """
            Reorganize this selected thread-note content into cleaner markdown without losing detail.

            Selected markdown to reorganize:
            \(snippet(normalizedSelectedText, limit: 24_000))\(noteContextSection)\(styleInstructionSection(normalizedStyleInstruction))

            Keep the amount of detail close to the source. Preserve examples, lists, and step-by-step explanations when they carry useful information.
            """
        } else {
            userPrompt = """
            Reorganize this full thread note into cleaner markdown without losing detail.

            Thread note markdown:
            \(snippet(normalizedNoteText, limit: 24_000))\(styleInstructionSection(normalizedStyleInstruction))

            Keep the amount of detail close to the source. Preserve examples, lists, and step-by-step explanations when they carry useful information.
            """
        }

        return ThreadNoteOrganizePrompt(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt
        )
    }

    private static func snippet(_ value: String, limit: Int) -> String {
        let normalized = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(max(0, limit - 3))) + "..."
    }

    private static func styleInstructionSection(_ value: String?) -> String {
        guard let value else { return "" }
        return """

        Requested formatting preference:
        \(snippet(value, limit: 1_200))
        """
    }
}

enum ThreadNoteScreenshotImportPromptBuilder {
    static func makePrompt(
        recognizedText: String?,
        styleInstruction: String? = nil,
        captureMode: ThreadNoteScreenshotCaptureMode = .area,
        segmentCount: Int = 1
    ) -> ThreadNoteOrganizePrompt {
        let normalizedRecognizedText = recognizedText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
        let normalizedStyleInstruction = styleInstruction?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty

        let systemPrompt = """
        You turn screenshot content into a clean note for a non-technical user.
        Output markdown only.
        Use simple wording, short headings, and readable bullets when they help.
        Preserve concrete facts, names, numbers, commands, filenames, labels, and key wording from the screenshot.
        When several screenshots cover the same topic, merge them into one concise note and remove obvious repetition.
        If the screenshot looks like UI text, convert it into a useful note instead of copying visual layout details.
        If the screenshot looks like a document, keep the important structure but remove obvious OCR noise.
        Do not mention OCR unless the user asks.
        Do not invent text that is not visible or strongly implied.
        Do not wrap the whole answer in a code fence.
        """

        let recognizedTextSection = normalizedRecognizedText.map {
            """

            OCR text found in the screenshot:
            \(snippet($0, limit: 14_000))
            """
        } ?? """

        OCR text found in the screenshot:
        (none)
        """

        let styleInstructionSection = normalizedStyleInstruction.map {
            """

            Requested formatting preference:
            \(snippet($0, limit: 1_200))
            """
        } ?? ""

        let normalizedSegmentCount = max(1, segmentCount)
        let captureContextSection: String = {
            guard captureMode != .area || normalizedSegmentCount > 1 else { return "" }

            switch captureMode {
            case .scrolling:
                return """

                This image combines \(normalizedSegmentCount) screenshots in top-to-bottom scroll order.
                Treat them as one continuous scrolling capture and preserve the reading order.
                """
            case .multiple:
                return """

                This image combines \(normalizedSegmentCount) separate screenshots arranged from top to bottom.
                If they cover the same topic, merge them into one combined summary and remove repeated details.
                Keep separate sections only when the screenshots are clearly about different subtopics.
                """
            case .area:
                return """

                This image combines \(normalizedSegmentCount) screenshots arranged from top to bottom.
                Preserve the useful order when turning them into a note.
                """
            }
        }()

        return ThreadNoteOrganizePrompt(
            systemPrompt: systemPrompt,
            userPrompt: """
            Convert this screenshot into note-ready markdown.
            \(recognizedTextSection)\(captureContextSection)\(styleInstructionSection)

            Focus on content that belongs in a note:
            - the main text
            - important labels or headings
            - useful details the user will want to keep
            """
        )
    }

    private static func snippet(_ value: String, limit: Int) -> String {
        let normalized = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(max(0, limit - 3))) + "..."
    }
}

actor MemoryEntryExplanationService {
    static let shared = MemoryEntryExplanationService()

    private enum ProviderCredential {
        case none
        case apiKey(String)
        case oauth(PromptRewriteOAuthSession)
    }

    private struct LiveConfiguration {
        let providerMode: PromptRewriteProviderMode
        let model: String
        let baseURL: String
        let apiKey: String
        let oauthSession: PromptRewriteOAuthSession?
    }

    private struct ResolvedConfiguration {
        let configuration: LiveConfiguration
        let credential: ProviderCredential
    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func explain(
        entry: MemoryIndexedEntry,
        onPartialText: (@Sendable (String) -> Void)? = nil
    ) async -> MemoryEntryExplanationResult {
        guard let resolved = await resolvedLiveConfiguration() else {
            return .failure("Connect at least one provider first to explain memories with AI.")
        }

        do {
            let request = try buildRequest(
                configuration: resolved.configuration,
                credential: resolved.credential,
                entry: entry
            )
            return try await executeRequest(
                request,
                configuration: resolved.configuration,
                credential: resolved.credential,
                emptyResultMessage: "Provider returned an empty explanation.",
                onPartialText: onPartialText
            )
        } catch {
            return .failure("Could not build explanation request. Check provider base URL.")
        }
    }

    func explainSelectedText(
        _ selectedText: String,
        parentMessageText: String,
        question: String? = nil,
        conversationHistory: [SelectionAskConversationTurn] = [],
        wholeChatSummary: String? = nil,
        onPartialText: (@Sendable (String) -> Void)? = nil
    ) async -> MemoryEntryExplanationResult {
        let normalizedSelection = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSelection.isEmpty else {
            return .failure("Select some text first.")
        }
        let normalizedParentMessage = parentMessageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedParentMessage.isEmpty else {
            return .failure("Could not find the full message for this selection.")
        }

        guard let resolved = await resolvedLiveConfiguration() else {
            return .failure("Connect at least one provider first to explain selected text with AI.")
        }

        let prompt = SelectionAskPromptBuilder.makePrompt(
            selectedText: normalizedSelection,
            parentMessageText: normalizedParentMessage,
            question: question,
            conversationHistory: conversationHistory,
            wholeChatSummary: wholeChatSummary
        )

        do {
            let request = try buildRequest(
                configuration: resolved.configuration,
                credential: resolved.credential,
                systemPrompt: prompt.systemPrompt,
                userPrompt: prompt.userPrompt,
                maxOutputTokens: 520
            )
            return try await executeRequest(
                request,
                configuration: resolved.configuration,
                credential: resolved.credential,
                emptyResultMessage: "Provider returned an empty answer.",
                onPartialText: onPartialText
            )
        } catch {
            return .failure("Could not build explanation request. Check provider base URL.")
        }
    }

    func explainSelectedTextDirectIfAvailable(
        _ selectedText: String,
        parentMessageText: String,
        question: String,
        preferredProviderMode: PromptRewriteProviderMode,
        preferredModel: String?,
        conversationHistory: [SelectionAskConversationTurn] = [],
        wholeChatSummary: String? = nil,
        onPartialText: (@Sendable (String) -> Void)? = nil
    ) async -> MemoryEntryExplanationResult? {
        let normalizedSelection = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSelection.isEmpty else {
            return .failure("Select some text first.")
        }
        let normalizedParentMessage = parentMessageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedParentMessage.isEmpty else {
            return .failure("Could not find the full message for this selection.")
        }

        guard let resolved = await resolvedLiveConfiguration(
            preferredProviderMode: preferredProviderMode,
            preferredModel: preferredModel
        ) else {
            return nil
        }

        let prompt = SelectionAskPromptBuilder.makePrompt(
            selectedText: normalizedSelection,
            parentMessageText: normalizedParentMessage,
            question: question,
            conversationHistory: conversationHistory,
            wholeChatSummary: wholeChatSummary
        )

        do {
            let request = try buildRequest(
                configuration: resolved.configuration,
                credential: resolved.credential,
                systemPrompt: prompt.systemPrompt,
                userPrompt: prompt.userPrompt,
                maxOutputTokens: 260
            )
            return try await executeRequest(
                request,
                configuration: resolved.configuration,
                credential: resolved.credential,
                emptyResultMessage: "Provider returned an empty answer.",
                onPartialText: onPartialText
            )
        } catch {
            return .failure("Could not build explanation request. Check provider base URL.")
        }
    }

    func organizeThreadNote(
        noteText: String,
        selectedText: String? = nil,
        styleInstruction: String? = nil,
        onPartialText: (@Sendable (String) -> Void)? = nil
    ) async -> MemoryEntryExplanationResult {
        let normalizedNoteText = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSelectedText = selectedText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty

        guard !normalizedNoteText.isEmpty || normalizedSelectedText != nil else {
            return .failure("There is no note text to organize yet.")
        }

        guard let resolved = await resolvedLiveConfiguration() else {
            return .failure("Connect at least one provider first to organize notes with AI.")
        }

        let prompt = ThreadNoteOrganizePromptBuilder.makePrompt(
            noteText: normalizedNoteText,
            selectedText: normalizedSelectedText,
            styleInstruction: styleInstruction
        )

        do {
            let request = try buildRequest(
                configuration: resolved.configuration,
                credential: resolved.credential,
                systemPrompt: prompt.systemPrompt,
                userPrompt: prompt.userPrompt,
                maxOutputTokens: normalizedSelectedText == nil ? 2_200 : 1_800
            )
            return try await executeRequest(
                request,
                configuration: resolved.configuration,
                credential: resolved.credential,
                emptyResultMessage: "Provider returned an empty note draft.",
                onPartialText: onPartialText
            )
        } catch {
            return .failure("Could not build note organization request. Check provider base URL.")
        }
    }

    func prepareThreadNoteScreenshotImport(
        attachment: AssistantAttachment,
        outputMode: ThreadNoteScreenshotImportMode,
        styleInstruction: String? = nil,
        captureMode: ThreadNoteScreenshotCaptureMode = .area,
        segmentCount: Int = 1
    ) async -> ThreadNoteScreenshotImportPreparationResult {
        guard attachment.mimeType.lowercased().hasPrefix("image/") else {
            return .failure("Use an image screenshot here.")
        }

        let recognizedText = recognizeScreenshotText(from: attachment.data)
        let normalizedRecognizedText = recognizedText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty

        if outputMode == .rawOCR {
            guard let normalizedRecognizedText else {
                return .failure(
                    "I could not find readable text in that screenshot. Try a tighter selection or use Clean text with a vision-capable model."
                )
            }

            return .success(
                ThreadNoteScreenshotImportPreparation(
                    markdown: normalizedRecognizedText,
                    rawText: normalizedRecognizedText,
                    usedVision: false
                )
            )
        }

        guard let resolved = await resolvedLiveConfiguration() else {
            return .failure("Connect at least one provider first to clean screenshot text with AI.")
        }

        let normalizedStyleInstruction = styleInstruction?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
        let prompt = ThreadNoteScreenshotImportPromptBuilder.makePrompt(
            recognizedText: normalizedRecognizedText,
            styleInstruction: normalizedStyleInstruction,
            captureMode: captureMode,
            segmentCount: segmentCount
        )
        let canUseVision = supportsVisionInput(configuration: resolved.configuration)
        let shouldPreferTextOnly = shouldPreferTextOnlyScreenshotImport(
            recognizedText: normalizedRecognizedText,
            attachmentByteCount: attachment.data.count,
            captureMode: captureMode,
            segmentCount: segmentCount
        )
        let primaryUsesVision = canUseVision && !shouldPreferTextOnly

        if !canUseVision, normalizedRecognizedText == nil {
            return .failure(
                "I could not find readable text in that screenshot, and the current model cannot read images directly. Try a tighter selection or choose a model with image input."
            )
        }

        do {
            let primaryRequest: URLRequest
            if primaryUsesVision {
                primaryRequest = try buildRequest(
                    configuration: resolved.configuration,
                    credential: resolved.credential,
                    systemPrompt: prompt.systemPrompt,
                    userPrompt: prompt.userPrompt,
                    maxOutputTokens: 1_400,
                    imageData: attachment.data,
                    imageMimeType: attachment.mimeType,
                    timeoutInterval: screenshotImportRequestTimeout(
                        outputMode: outputMode,
                        captureMode: captureMode,
                        segmentCount: segmentCount,
                        attachmentByteCount: attachment.data.count,
                        usingVision: true
                    )
                )
            } else {
                primaryRequest = try buildRequest(
                    configuration: resolved.configuration,
                    credential: resolved.credential,
                    systemPrompt: prompt.systemPrompt,
                    userPrompt: prompt.userPrompt,
                    maxOutputTokens: 1_400,
                    timeoutInterval: screenshotImportRequestTimeout(
                        outputMode: outputMode,
                        captureMode: captureMode,
                        segmentCount: segmentCount,
                        attachmentByteCount: attachment.data.count,
                        usingVision: false
                    )
                )
            }

            let result = try await executeRequest(
                primaryRequest,
                configuration: resolved.configuration,
                credential: resolved.credential,
                emptyResultMessage: "Provider returned an empty screenshot note draft."
            )

            switch result {
            case .success(let markdown):
                let normalizedMarkdown = markdown
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalizedMarkdown.isEmpty else {
                    return .failure("The screenshot preview came back empty. Please try again.")
                }
                return .success(
                    ThreadNoteScreenshotImportPreparation(
                        markdown: normalizedMarkdown,
                        rawText: normalizedRecognizedText ?? "",
                        usedVision: primaryUsesVision
                    )
                )
            case .failure(let message):
                if primaryUsesVision,
                    let normalizedRecognizedText,
                    shouldRetryScreenshotImportWithoutVision(after: message)
                {
                    let fallbackRequest = try buildRequest(
                        configuration: resolved.configuration,
                        credential: resolved.credential,
                        systemPrompt: prompt.systemPrompt,
                        userPrompt: prompt.userPrompt,
                        maxOutputTokens: 1_400,
                        timeoutInterval: screenshotImportRequestTimeout(
                            outputMode: outputMode,
                            captureMode: captureMode,
                            segmentCount: segmentCount,
                            attachmentByteCount: attachment.data.count,
                            usingVision: false
                        )
                    )

                    let fallbackResult = try await executeRequest(
                        fallbackRequest,
                        configuration: resolved.configuration,
                        credential: resolved.credential,
                        emptyResultMessage: "Provider returned an empty screenshot note draft."
                    )

                    switch fallbackResult {
                    case .success(let markdown):
                        let normalizedMarkdown = markdown
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !normalizedMarkdown.isEmpty else {
                            return .failure("The screenshot preview came back empty. Please try again.")
                        }
                        return .success(
                            ThreadNoteScreenshotImportPreparation(
                                markdown: normalizedMarkdown,
                                rawText: normalizedRecognizedText,
                                usedVision: false
                            )
                        )
                    case .failure(let fallbackMessage):
                        return .failure(fallbackMessage)
                    }
                }
                return .failure(message)
            }
        } catch {
            return .failure("Could not build screenshot note request. Check provider base URL.")
        }
    }

    private func shouldPreferTextOnlyScreenshotImport(
        recognizedText: String?,
        attachmentByteCount: Int,
        captureMode: ThreadNoteScreenshotCaptureMode,
        segmentCount: Int
    ) -> Bool {
        guard recognizedText != nil else { return false }

        let normalizedSegmentCount = max(1, segmentCount)
        if captureMode == .multiple && normalizedSegmentCount >= 4 {
            return true
        }

        if captureMode == .scrolling && normalizedSegmentCount >= 5 {
            return true
        }

        return attachmentByteCount >= 5_500_000
    }

    private func shouldRetryScreenshotImportWithoutVision(after message: String) -> Bool {
        let normalized = message
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if normalized.isEmpty {
            return false
        }

        let retryableFragments = [
            "timed out",
            "timeout",
            "too large",
            "413",
            "body too large",
            "context length",
            "request entity too large"
        ]
        return retryableFragments.contains { normalized.contains($0) }
    }

    private func screenshotImportRequestTimeout(
        outputMode: ThreadNoteScreenshotImportMode,
        captureMode: ThreadNoteScreenshotCaptureMode,
        segmentCount: Int,
        attachmentByteCount: Int,
        usingVision: Bool
    ) -> TimeInterval {
        let normalizedSegmentCount = max(1, segmentCount)
        let megabytes = Double(max(0, attachmentByteCount)) / 1_000_000

        if outputMode == .rawOCR {
            return 20
        }

        var timeout: TimeInterval = usingVision ? 45 : 30

        switch captureMode {
        case .area:
            timeout += Double(max(0, normalizedSegmentCount - 1)) * 4
        case .scrolling:
            timeout += Double(max(0, normalizedSegmentCount - 1)) * 8
        case .multiple:
            timeout += Double(max(0, normalizedSegmentCount - 1)) * 12
        }

        if usingVision {
            timeout += min(30, megabytes * 3)
        } else {
            timeout += min(12, megabytes)
        }

        return min(150, max(20, timeout))
    }

    func generateBatchNotePlan(
        sourceNotes: [AssistantBatchNotePlanSourceContext]
    ) async -> AssistantBatchNotePlanGenerationResult {
        guard !sourceNotes.isEmpty else {
            return .failure("Select at least one source note first.")
        }

        guard let resolved = await resolvedLiveConfiguration() else {
            return .failure("Connect at least one provider first to organize notes with AI.")
        }

        let prompt = BatchNotePlanPromptBuilder.makePrompt(sourceNotes: sourceNotes)

        do {
            let request = try buildRequest(
                configuration: resolved.configuration,
                credential: resolved.credential,
                systemPrompt: prompt.systemPrompt,
                userPrompt: prompt.userPrompt,
                maxOutputTokens: 3_000
            )
            let result = try await executeRequest(
                request,
                configuration: resolved.configuration,
                credential: resolved.credential,
                emptyResultMessage: "Provider returned an empty note plan."
            )

            switch result {
            case .success(let response):
                do {
                    let parsed = try AssistantBatchNotePlanParser.parseResponse(
                        response,
                        allowedSourceRefs: Set(sourceNotes.map(\.ref))
                    )
                    return .success(parsed)
                } catch {
                    let message = (error as? LocalizedError)?.errorDescription
                        ?? "AI returned a note plan in an unexpected format."
                    return .failure(message)
                }
            case .failure(let message):
                return .failure(message)
            }
        } catch {
            return .failure("Could not build the batch note organization request. Check provider base URL.")
        }
    }

    func generateThreadNoteChart(
        selectedText: String,
        parentMessageText: String,
        currentDraft: String? = nil,
        styleInstruction: String? = nil,
        validationError: String? = nil
    ) async -> MemoryEntryExplanationResult {
        let normalizedSelection = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSelection.isEmpty else {
            return .failure("Select some text first.")
        }

        let normalizedParentMessage = parentMessageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedParentMessage.isEmpty else {
            return .failure("Could not find the full message for this selection.")
        }

        guard let resolved = await resolvedLiveConfiguration() else {
            return .failure("Connect at least one provider first to generate charts with AI.")
        }

        let prompt = ThreadNoteChartPromptBuilder.makePrompt(
            selectedText: normalizedSelection,
            parentMessageText: normalizedParentMessage,
            currentDraft: currentDraft,
            styleInstruction: styleInstruction,
            validationError: validationError
        )

        do {
            let request = try buildRequest(
                configuration: resolved.configuration,
                credential: resolved.credential,
                systemPrompt: prompt.systemPrompt,
                userPrompt: prompt.userPrompt,
                maxOutputTokens: 520
            )
            return try await executeRequest(
                request,
                configuration: resolved.configuration,
                credential: resolved.credential,
                emptyResultMessage: "Provider returned an empty chart draft."
            )
        } catch {
            return .failure("Could not build chart generation request. Check provider base URL.")
        }
    }

    func suggestProjectNoteTransfer(
        selectedMarkdown: String,
        sourceNoteTitle: String,
        targetNoteTitle: String,
        targetHeadingOutline: String,
        targetNoteText: String
    ) async -> ProjectNoteTransferSuggestionResult {
        let normalizedSelection = selectedMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSelection.isEmpty else {
            return .failure("Select some note content first.")
        }

        let normalizedTargetTitle = targetNoteTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTargetTitle.isEmpty else {
            return .failure("Choose a project note first.")
        }

        guard let resolved = await resolvedLiveConfiguration() else {
            return .failure("Connect at least one provider first to place note content with AI.")
        }

        let normalizedSourceTitle = sourceNoteTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedOutline = targetHeadingOutline.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTargetText = targetNoteText.trimmingCharacters(in: .whitespacesAndNewlines)

        let systemPrompt = """
        You place selected thread-note content into an existing project note.
        Output JSON only.
        Do not wrap the JSON in markdown fences.
        Do not invent facts.
        You may lightly organize the selected markdown so it fits the target note better.
        Keep the meaning, decisions, constraints, and action items intact.
        Choose the single best heading path in the target note, or use "END" if no safe section fits.
        Use this JSON shape exactly:
        {
          "headingPath": ["Heading", "Child Heading"] or "END",
          "insertedMarkdown": "markdown to insert",
          "reason": "short plain-language reason"
        }
        """

        let userPrompt = """
        Source thread note title:
        \(snippet(normalizedSourceTitle.isEmpty ? "Untitled note" : normalizedSourceTitle, limit: 200))

        Selected markdown to move or copy:
        \(snippet(normalizedSelection, limit: 12_000))

        Target project note title:
        \(snippet(normalizedTargetTitle, limit: 200))

        Target project note heading outline:
        \(snippet(normalizedOutline.isEmpty ? "No headings yet." : normalizedOutline, limit: 5_000))

        Target project note markdown:
        \(snippet(normalizedTargetText, limit: 18_000))
        """

        do {
            let request = try buildRequest(
                configuration: resolved.configuration,
                credential: resolved.credential,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                maxOutputTokens: 720
            )
            let result = try await executeRequest(
                request,
                configuration: resolved.configuration,
                credential: resolved.credential,
                emptyResultMessage: "Provider returned an empty placement suggestion."
            )

            switch result {
            case .success(let response):
                guard let suggestion = parseProjectNoteTransferSuggestion(from: response) else {
                    return .failure("AI returned a placement suggestion in an unexpected format.")
                }
                return .success(suggestion)
            case .failure(let message):
                return .failure(message)
            }
        } catch {
            return .failure("Could not build project-note placement request. Check provider base URL.")
        }
    }

    private func buildRequest(
        configuration: LiveConfiguration,
        credential: ProviderCredential,
        entry: MemoryIndexedEntry
    ) throws -> URLRequest {
        let memoryInstructionSummary = summarizeMemoryInstruction(for: entry)
        let systemPrompt = """
        You explain a saved AI memory entry in simple terms for a non-technical user.
        Output plain text only.
        Include:
        1) what this memory is
        2) why it was saved
        3) when it should influence prompt rewriting
        Keep it concise and actionable.
        """

        let userPrompt = """
        Memory entry:
        - title: \(snippet(entry.title, limit: 220))
        - summary: \(snippet(entry.summary, limit: 400))
        - detail: \(snippet(entry.detail, limit: 3000))
        - provider: \(entry.provider.displayName)
        - source: \(snippet(entry.sourceRootPath, limit: 260))
        - source_file: \(snippet(entry.sourceFileRelativePath, limit: 260))
        - project: \(snippet(entry.projectName ?? "", limit: 160))
        - repository: \(snippet(entry.repositoryName ?? "", limit: 160))
        - updated_at: \(entry.updatedAt.formatted(date: .abbreviated, time: .standard))
        - is_plan_content: \(entry.isPlanContent ? "true" : "false")
        """

        return try buildRequest(
            configuration: configuration,
            credential: credential,
            systemPrompt: """
            \(systemPrompt)
            Memory summary instruction:
            \(memoryInstructionSummary)
            """,
            userPrompt: userPrompt,
            maxOutputTokens: 520
        )
    }

    private func buildRequest(
        configuration: LiveConfiguration,
        credential: ProviderCredential,
        systemPrompt: String,
        userPrompt: String,
        maxOutputTokens: Int,
        imageData: Data? = nil,
        imageMimeType: String? = nil,
        timeoutInterval: TimeInterval = 25
    ) throws -> URLRequest {
        let trimmedSystemPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUserPrompt = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedImageMimeType = imageMimeType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .nonEmpty ?? "image/png"
        let imageDataURL = imageData.map {
            "data:\(normalizedImageMimeType);base64,\($0.base64EncodedString())"
        }

        let endpoint: URL?
        let payload: [String: Any]
        switch configuration.providerMode {
        case .openAI where isOAuth(credential):
            endpoint = URL(string: "https://chatgpt.com/backend-api/codex/responses")
            let userContent: [[String: Any]]
            if let imageDataURL {
                userContent = [
                    ["type": "input_text", "text": trimmedUserPrompt],
                    ["type": "input_image", "image_url": imageDataURL]
                ]
            } else {
                userContent = [
                    ["type": "input_text", "text": trimmedUserPrompt]
                ]
            }
            payload = [
                "model": configuration.model,
                "store": false,
                "stream": true,
                "instructions": trimmedSystemPrompt,
                "input": [
                    [
                        "role": "system",
                        "content": [
                            ["type": "input_text", "text": trimmedSystemPrompt]
                        ]
                    ],
                    [
                        "role": "user",
                        "content": userContent
                    ]
                ]
            ]
        case .anthropic:
            endpoint = anthropicMessagesEndpoint(from: configuration.baseURL)
            let userContent: [[String: Any]]
            if let imageData {
                userContent = [
                    [
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": normalizedImageMimeType,
                            "data": imageData.base64EncodedString()
                        ]
                    ],
                    ["type": "text", "text": trimmedUserPrompt]
                ]
            } else {
                userContent = [
                    ["type": "text", "text": trimmedUserPrompt]
                ]
            }
            payload = [
                "model": configuration.model,
                "system": trimmedSystemPrompt,
                "messages": [
                    ["role": "user", "content": userContent]
                ],
                "temperature": 0.2,
                "max_tokens": maxOutputTokens
            ]
        case .openAI, .google, .openRouter, .groq, .ollama:
            endpoint = openAICompatibleEndpoint(from: configuration.baseURL)
            let userContent: Any
            if let imageDataURL {
                userContent = [
                    ["type": "text", "text": trimmedUserPrompt],
                    ["type": "image_url", "image_url": ["url": imageDataURL]]
                ]
            } else {
                userContent = trimmedUserPrompt
            }
            payload = [
                "model": configuration.model,
                "temperature": 0.2,
                "max_tokens": maxOutputTokens,
                "messages": [
                    ["role": "system", "content": trimmedSystemPrompt],
                    ["role": "user", "content": userContent]
                ]
            ]
        }

        guard let endpoint else {
            throw NSError(domain: "MemoryEntryExplanation", code: 1)
        }
        guard JSONSerialization.isValidJSONObject(payload),
              let body = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            throw NSError(domain: "MemoryEntryExplanation", code: 2)
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutInterval
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        switch (configuration.providerMode, credential) {
        case (.anthropic, .oauth(let oauthSession)):
            request.setValue("Bearer \(oauthSession.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(
                "oauth-2025-04-20,interleaved-thinking-2025-05-14",
                forHTTPHeaderField: "anthropic-beta"
            )
            request.setValue("claude-cli/2.1.2 (external, cli)", forHTTPHeaderField: "User-Agent")
        case (.anthropic, .apiKey(let apiKey)):
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case (.openAI, .oauth(let oauthSession)):
            request.setValue("Bearer \(oauthSession.accessToken)", forHTTPHeaderField: "Authorization")
            if let accountID = oauthSession.accountID,
               !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
            }
        case (.openAI, .apiKey(let apiKey)),
             (.google, .apiKey(let apiKey)),
             (.openRouter, .apiKey(let apiKey)),
             (.groq, .apiKey(let apiKey)),
             (.ollama, .apiKey(let apiKey)):
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case (.anthropic, .none),
             (.openAI, .none),
             (.google, .none),
             (.openRouter, .none),
             (.groq, .none),
             (.ollama, .none),
             (.google, .oauth),
             (.openRouter, .oauth),
             (.groq, .oauth),
             (.ollama, .oauth):
            break
        }

        return request
    }

    private func recognizeScreenshotText(from imageData: Data) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        do {
            let handler = VNImageRequestHandler(data: imageData, options: [:])
            try handler.perform([request])
        } catch {
            return nil
        }

        let observations = (request.results ?? []).sorted { lhs, rhs in
            let leftTop = lhs.boundingBox.maxY
            let rightTop = rhs.boundingBox.maxY
            if abs(leftTop - rightTop) < 0.03 {
                return lhs.boundingBox.minX < rhs.boundingBox.minX
            }
            return leftTop > rightTop
        }

        let lines = observations.compactMap { observation in
            observation.topCandidates(1).first?
                .string
                .replacingOccurrences(of: "\r\n", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty
        }

        let normalized = lines.joined(separator: "\n")
            .replacingOccurrences(
                of: #"\n{3,}"#,
                with: "\n\n",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.nonEmpty
    }

    private func supportsVisionInput(configuration: LiveConfiguration) -> Bool {
        let normalizedModel = configuration.model
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if normalizedModel.contains("vision")
            || normalizedModel.contains("gpt-4o")
            || normalizedModel.contains("gpt-4.1")
            || normalizedModel.contains("gemini")
            || normalizedModel.contains("claude-3")
            || normalizedModel.contains("claude-4")
            || normalizedModel.contains("sonnet-4")
            || normalizedModel.contains("opus-4")
            || normalizedModel.contains("haiku-3")
            || normalizedModel.contains("llava")
            || normalizedModel.contains("pixtral")
            || normalizedModel.contains("gemma-3")
            || normalizedModel.contains("gemma3")
            || normalizedModel.contains("vl") {
            return true
        }

        switch configuration.providerMode {
        case .google:
            return normalizedModel.contains("gemini")
        case .anthropic:
            return normalizedModel.contains("claude")
        case .openAI:
            return normalizedModel.contains("gpt")
        case .openRouter, .groq, .ollama:
            return false
        }
    }

    private func executeRequest(
        _ request: URLRequest,
        configuration: LiveConfiguration,
        credential: ProviderCredential,
        emptyResultMessage: String,
        onPartialText: (@Sendable (String) -> Void)? = nil
    ) async throws -> MemoryEntryExplanationResult {
        let isStreamingCodex = configuration.providerMode == .openAI && isOAuth(credential)

        let streamingResponse: StreamingTextHTTPResponse
        do {
            streamingResponse = try await StreamingTextResponseReader.collect(
                using: session,
                request: request,
                expectsEventStream: isStreamingCodex,
                onPartialText: onPartialText
            )
        } catch {
            let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return .failure("Provider request failed.")
            }
            return .failure("Provider request failed: \(detail)")
        }

        let data = streamingResponse.data
        let response = streamingResponse.response

        guard let http = response as? HTTPURLResponse else {
            return .failure("Provider returned an invalid response.")
        }
        guard (200...299).contains(http.statusCode) else {
            let detail = providerErrorDetail(from: data) ?? "HTTP \(http.statusCode)"
            return .failure("Provider request failed (\(http.statusCode)): \(detail)")
        }

        let content: String
        if isStreamingCodex {
            content =
                streamingResponse.streamedText?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty
                ?? decodeSSEContent(data: data)
        } else if configuration.providerMode == .anthropic {
            content = decodeAnthropicContent(data: data)
        } else {
            content = decodeOpenAICompatibleContent(data: data)
        }

        let normalized = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return .failure(emptyResultMessage)
        }
        return .success(normalized)
    }

    private func summarizeMemoryInstruction(for entry: MemoryIndexedEntry) -> String {
        let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = entry.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = entry.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty {
            return "\(title.isEmpty ? "Untitled memory" : title): \(snippet(summary, limit: 220))"
        }
        if !detail.isEmpty {
            return "\(title.isEmpty ? "Untitled memory" : title): \(snippet(detail, limit: 220))"
        }
        return title.isEmpty ? "No memory content available." : title
    }

    private func resolveCredential(for configuration: LiveConfiguration) async throws -> ProviderCredential {
        if let oauthSession = configuration.oauthSession, configuration.providerMode.supportsOAuthSignIn {
            let refreshed = try await PromptRewriteProviderOAuthService.shared.refreshSessionIfNeeded(
                oauthSession,
                providerMode: configuration.providerMode
            )
            return .oauth(refreshed)
        }

        let apiKey = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !apiKey.isEmpty {
            return .apiKey(apiKey)
        }
        return .none
    }

    private func resolvedLiveConfiguration(
        preferredProviderMode: PromptRewriteProviderMode? = nil,
        preferredModel: String? = nil
    ) async -> ResolvedConfiguration? {
        let preferredModel = preferredModel?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty

        let candidateConfigurations: [LiveConfiguration]
        if let preferredProviderMode {
            candidateConfigurations = liveConfigurations()
                .filter { $0.providerMode == preferredProviderMode }
                .map { configuration in
                    LiveConfiguration(
                        providerMode: configuration.providerMode,
                        model: preferredModel ?? configuration.model,
                        baseURL: configuration.baseURL,
                        apiKey: configuration.apiKey,
                        oauthSession: configuration.oauthSession
                    )
                }
        } else {
            candidateConfigurations = liveConfigurations()
        }

        for configuration in candidateConfigurations {
            let credential: ProviderCredential
            do {
                credential = try await resolveCredential(for: configuration)
            } catch {
                continue
            }

            if configuration.providerMode.requiresAPIKey,
               case .none = credential {
                continue
            }

            return ResolvedConfiguration(
                configuration: configuration,
                credential: credential
            )
        }

        return nil
    }

    private func liveConfigurations() -> [LiveConfiguration] {
        let defaults = UserDefaults.standard
        let selectedProviderMode = loadProviderMode(defaults: defaults)
        let legacyModel = defaults
            .string(forKey: "OpenAssist.promptRewriteOpenAIModel")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
        let legacyBaseURL = defaults
            .string(forKey: "OpenAssist.promptRewriteOpenAIBaseURL")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty

        var modelsByProvider = normalizedProviderScopedStringDictionary(
            defaults.dictionary(forKey: "OpenAssist.promptRewriteModelByProvider")
        )
        var baseURLsByProvider = normalizedProviderScopedStringDictionary(
            defaults.dictionary(forKey: "OpenAssist.promptRewriteBaseURLByProvider")
        )

        if modelsByProvider[selectedProviderMode.rawValue] == nil,
           modelsByProvider.isEmpty,
           let legacyModel {
            modelsByProvider[selectedProviderMode.rawValue] = legacyModel
        }

        if baseURLsByProvider[selectedProviderMode.rawValue] == nil,
           baseURLsByProvider.isEmpty,
           let legacyBaseURL {
            baseURLsByProvider[selectedProviderMode.rawValue] = legacyBaseURL
        }

        let orderedModes = [selectedProviderMode]
            + PromptRewriteProviderMode.allCases.filter { $0 != selectedProviderMode }

        var configurations: [LiveConfiguration] = []
        for providerMode in orderedModes {
            let oauthSession = PromptRewriteOAuthCredentialStore.loadSession(for: providerMode)
            let apiKey = loadProviderAPIKey(for: providerMode)
            let hasCredentials = oauthSession != nil || !apiKey.isEmpty || !providerMode.requiresAPIKey
            guard hasCredentials else { continue }

            let restoredModel = modelsByProvider[providerMode.rawValue]
                ?? (providerMode == selectedProviderMode ? legacyModel : nil)
                ?? providerMode.defaultModel
            let restoredBaseURL = baseURLsByProvider[providerMode.rawValue]
                ?? (providerMode == selectedProviderMode ? legacyBaseURL : nil)
                ?? providerMode.defaultBaseURL
            let sanitized = sanitizedConfiguration(
                for: providerMode,
                model: restoredModel,
                baseURL: restoredBaseURL,
                hasOAuthSession: oauthSession != nil,
                hasAPIKey: !apiKey.isEmpty
            )

            configurations.append(
                LiveConfiguration(
                    providerMode: providerMode,
                    model: sanitized.model,
                    baseURL: sanitized.baseURL,
                    apiKey: apiKey,
                    oauthSession: oauthSession
                )
            )
        }

        return configurations
    }

    private func parseProjectNoteTransferSuggestion(
        from response: String
    ) -> ProjectNoteTransferSuggestion? {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let candidates = [trimmed, extractJSONObject(from: trimmed)].compactMap { $0 }

        for candidate in candidates {
            guard let data = candidate.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let insertedMarkdown = (json["insertedMarkdown"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let insertedMarkdown, !insertedMarkdown.isEmpty else {
                continue
            }

            let reason = (json["reason"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty
                ?? "This location fits the target note structure."

            let headingPath: [String]?
            if let headingPathString = (json["headingPath"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty {
                headingPath = headingPathString.caseInsensitiveCompare("END") == .orderedSame
                    ? nil
                    : [headingPathString]
            } else if let headingPathValues = json["headingPath"] as? [Any] {
                let normalizedPath = headingPathValues.compactMap {
                    ($0 as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .nonEmpty
                }
                headingPath = normalizedPath.isEmpty ? nil : normalizedPath
            } else {
                headingPath = nil
            }

            return ProjectNoteTransferSuggestion(
                headingPath: headingPath,
                insertedMarkdown: insertedMarkdown,
                reason: reason
            )
        }

        return nil
    }

    private func extractJSONObject(from value: String) -> String? {
        guard let start = value.firstIndex(of: "{"),
              let end = value.lastIndex(of: "}") else {
            return nil
        }

        let jsonSlice = value[start...end]
        let normalized = jsonSlice.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private func sanitizedConfiguration(
        for providerMode: PromptRewriteProviderMode,
        model: String,
        baseURL: String,
        hasOAuthSession: Bool,
        hasAPIKey: Bool
    ) -> (model: String, baseURL: String) {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        var resolvedModel = trimmedModel.isEmpty ? providerMode.defaultModel : trimmedModel
        var resolvedBaseURL = trimmedBaseURL.isEmpty ? providerMode.defaultBaseURL : trimmedBaseURL

        guard providerMode == .openAI else {
            return (resolvedModel, resolvedBaseURL)
        }

        let usingOpenAIOAuthOnly = hasOAuthSession && !hasAPIKey
        guard usingOpenAIOAuthOnly else {
            return (resolvedModel, resolvedBaseURL)
        }

        resolvedBaseURL = providerMode.defaultBaseURL
        if !PromptRewriteModelCatalogService.isOpenAIOAuthCompatibleModelID(resolvedModel) {
            resolvedModel = PromptRewriteModelCatalogService.defaultOpenAIOAuthModelID
        }
        return (resolvedModel, resolvedBaseURL)
    }

    private func normalizedProviderScopedStringDictionary(
        _ dictionary: [String: Any]?
    ) -> [String: String] {
        guard let dictionary else { return [:] }
        let validProviderIDs = Set(PromptRewriteProviderMode.allCases.map(\.rawValue))
        var normalized: [String: String] = [:]

        for (rawKey, rawValue) in dictionary {
            guard validProviderIDs.contains(rawKey) else { continue }
            guard let value = rawValue as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            normalized[rawKey] = trimmed
        }

        return normalized
    }

    private func loadProviderMode(defaults: UserDefaults) -> PromptRewriteProviderMode {
        let raw = defaults
            .string(forKey: "OpenAssist.promptRewriteProviderMode")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        switch raw {
        case "openai":
            return .openAI
        case "google", "gemini", "google ai studio (gemini)", "google-ai-studio-gemini":
            return .google
        case "openrouter":
            return .openRouter
        case "groq":
            return .groq
        case "anthropic":
            return .anthropic
        case "ollama (local)", "ollama":
            return .ollama
        case "local memory", "local-memory", "local":
            return .openAI
        default:
            return .openAI
        }
    }

    private func loadProviderAPIKey(for providerMode: PromptRewriteProviderMode) -> String {
        guard providerMode.requiresAPIKey else { return "" }

        if let envValue = ProcessInfo.processInfo.environment["OPENASSIST_PROMPT_REWRITE_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !envValue.isEmpty {
            return envValue
        }

        if let envValue = ProcessInfo.processInfo.environment["OPENASSIST_OPENAI_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !envValue.isEmpty {
            return envValue
        }
        if providerMode == .google {
            if let envValue = ProcessInfo.processInfo.environment["OPENASSIST_GOOGLE_API_KEY"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !envValue.isEmpty {
                return envValue
            }
            if let envValue = ProcessInfo.processInfo.environment["OPENASSIST_GEMINI_API_KEY"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !envValue.isEmpty {
                return envValue
            }
        }

        let normalizedProviderSlug = providerMode.rawValue
            .lowercased()
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .replacingOccurrences(of: " ", with: "-")
        let providerAccount = "prompt-rewrite-provider-api-key.\(normalizedProviderSlug)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.developingadventures.OpenAssist",
            kSecAttrAccount as String: providerAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status != errSecSuccess, providerMode == .openAI {
            let legacyQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.developingadventures.OpenAssist",
                kSecAttrAccount as String: "prompt-rewrite-openai-api-key",
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var legacyItem: CFTypeRef?
            let legacyStatus = SecItemCopyMatching(legacyQuery as CFDictionary, &legacyItem)
            guard legacyStatus == errSecSuccess,
                  let legacyData = legacyItem as? Data,
                  let legacyValue = String(data: legacyData, encoding: .utf8) else {
                return ""
            }
            return legacyValue.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if status != errSecSuccess {
            return ""
        }
        guard let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return ""
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isOAuth(_ credential: ProviderCredential) -> Bool {
        if case .oauth = credential {
            return true
        }
        return false
    }

    private func openAICompatibleEndpoint(from baseURL: String) -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalizedBase = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        return URL(string: normalizedBase + "/chat/completions")
    }

    private func anthropicMessagesEndpoint(from baseURL: String) -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalizedBase = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        return URL(string: normalizedBase + "/messages")
    }

    private func decodeOpenAICompatibleContent(data: Data) -> String {
        guard let root = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any],
              !root.isEmpty else {
            return ""
        }

        if let outputText = root["output_text"] as? String,
           !outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return outputText
        }

        if let output = root["output"] as? [[String: Any]] {
            let flattened = output.compactMap { item -> String? in
                if let content = item["content"] as? [[String: Any]] {
                    let joined = content.compactMap { block -> String? in
                        if let text = block["text"] as? String { return text }
                        if let text = block["output_text"] as? String { return text }
                        return nil
                    }.joined(separator: "\n")
                    if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return joined
                    }
                }
                return nil
            }.joined(separator: "\n")
            if !flattened.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return flattened
            }
        }

        guard let choices = root["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any] else {
            return ""
        }

        if let contentString = message["content"] as? String {
            return contentString
        }
        if let contentArray = message["content"] as? [[String: Any]] {
            return contentArray.compactMap { item in
                if let text = item["text"] as? String { return text }
                if let text = item["content"] as? String { return text }
                return nil
            }.joined(separator: "\n")
        }
        return ""
    }

    private func decodeAnthropicContent(data: Data) -> String {
        guard let root = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any],
              let contentArray = root["content"] as? [[String: Any]] else {
            return ""
        }
        return contentArray.compactMap { item in
            if let text = item["text"] as? String {
                return text
            }
            if let text = item["content"] as? String {
                return text
            }
            return nil
        }.joined(separator: "\n")
    }

    private func decodeSSEContent(data: Data) -> String {
        guard let raw = String(data: data, encoding: .utf8) else { return "" }
        var textParts: [String] = []
        for line in raw.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("data: ") else { continue }
            let jsonString = String(trimmed.dropFirst(6))
            if jsonString == "[DONE]" { continue }
            guard let jsonData = jsonString.data(using: .utf8),
                  let event = (try? JSONSerialization.jsonObject(with: jsonData)) as? [String: Any] else {
                continue
            }
            if let extracted = StreamingTextResponseReader.extractText(fromEventPayload: event) {
                let eventType = (event["type"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() ?? ""
                if eventType == "response.completed" || eventType.hasSuffix(".done") {
                    return extracted
                }
                textParts.append(extracted)
            }
        }
        return textParts.joined()
    }

    private func providerErrorDetail(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let dictionary = object as? [String: Any] {
            if let detail = dictionary["error_description"] as? String {
                let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            if let detail = dictionary["error"] as? String {
                let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            if let error = dictionary["error"] as? [String: Any],
               let detail = error["message"] as? String {
                let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            if let message = dictionary["message"] as? String {
                let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }

        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func snippet(_ value: String, limit: Int) -> String {
        let normalized = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(max(0, limit - 3))) + "..."
    }
}
