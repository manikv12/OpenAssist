import Foundation
import Security

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
        styleInstruction: String? = nil
    ) -> ThreadNoteChartPrompt {
        let normalizedSelection = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedParentMessage = parentMessageText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCurrentDraft = currentDraft?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
        let normalizedStyleInstruction = styleInstruction?
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
        You turn selected chat content into a Mermaid chart for a non-technical user.
        Output markdown only.
        Return exactly:
        1. a short markdown heading
        2. one Mermaid fenced code block
        Do not include extra explanation before or after the chart.
        Do not output more than one Mermaid block.
        Keep node labels short, clear, and easy to scan.
        Prefer simple structure over dense detail.
        Use only supported Mermaid types.
        For hierarchy or stack breakdowns, prefer mindmap, block-beta, architecture-beta, or a grouped flowchart.
        For step-by-step processes, prefer flowchart or sequenceDiagram.
        For dated phases, prefer timeline or gantt.
        For data/entity relationships, prefer erDiagram or classDiagram.
        For flowcharts, if a subgraph label has spaces or punctuation, write it like subgraph Core["RAPID Core (shared)"].
        Do not write flowchart subgraph titles like subgraph Core[RAPID Core (shared)].
        Quote labels that contain punctuation such as parentheses, slashes, colons, or commas.
        Use ASCII characters only.

        \(supportedTypes)
        """

        let userPrompt: String
        if let normalizedStyleInstruction {
            let currentDraftSection = normalizedCurrentDraft.map {
                """

                Current chart draft:
                \(snippet($0, limit: 14_000))
                """
            } ?? ""

            userPrompt = """
            Regenerate the chart from this selected chat content.

            Selected text:
            \(snippet(normalizedSelection, limit: 10_000))

            Full message context:
            \(snippet(normalizedParentMessage, limit: 16_000))\(currentDraftSection)

            Change request:
            \(snippet(normalizedStyleInstruction, limit: 1_200))
            """
        } else {
            userPrompt = """
            Create the best Mermaid chart for this selected chat content.

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

        let systemPrompt = """
        You organize thread notes for a non-technical user.
        Output markdown only.
        Use simple wording, short headings, and clear bullet points.
        Keep important facts, decisions, action items, and constraints.
        Do not invent missing details.
        Do not wrap the whole answer in a code fence.
        """

        let userPrompt: String
        if let normalizedSelectedText {
            userPrompt = """
            Organize this selected portion of a thread note into cleaner markdown.

            Full note context:
            \(snippet(normalizedNoteText, limit: 18_000))

            Selected portion to organize:
            \(snippet(normalizedSelectedText, limit: 12_000))
            """
        } else {
            userPrompt = """
            Organize this full thread note into cleaner markdown.

            Note:
            \(snippet(normalizedNoteText, limit: 18_000))
            """
        }

        do {
            let request = try buildRequest(
                configuration: resolved.configuration,
                credential: resolved.credential,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                maxOutputTokens: 520
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

    func generateThreadNoteChart(
        selectedText: String,
        parentMessageText: String,
        currentDraft: String? = nil,
        styleInstruction: String? = nil
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
            styleInstruction: styleInstruction
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
        maxOutputTokens: Int
    ) throws -> URLRequest {
        let trimmedSystemPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUserPrompt = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)

        let endpoint: URL?
        let payload: [String: Any]
        switch configuration.providerMode {
        case .openAI where isOAuth(credential):
            endpoint = URL(string: "https://chatgpt.com/backend-api/codex/responses")
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
                        "content": [
                            ["type": "input_text", "text": trimmedUserPrompt]
                        ]
                    ]
                ]
            ]
        case .anthropic:
            endpoint = anthropicMessagesEndpoint(from: configuration.baseURL)
            payload = [
                "model": configuration.model,
                "system": trimmedSystemPrompt,
                "messages": [
                    ["role": "user", "content": trimmedUserPrompt]
                ],
                "temperature": 0.2,
                "max_tokens": maxOutputTokens
            ]
        case .openAI, .google, .openRouter, .groq, .ollama:
            endpoint = openAICompatibleEndpoint(from: configuration.baseURL)
            payload = [
                "model": configuration.model,
                "temperature": 0.2,
                "max_tokens": maxOutputTokens,
                "messages": [
                    ["role": "system", "content": trimmedSystemPrompt],
                    ["role": "user", "content": trimmedUserPrompt]
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
        request.timeoutInterval = 25
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
            content = decodeSSEContent(data: data)
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
            // Responses API streaming: look for output_text.delta
            if let delta = event["delta"] as? String {
                textParts.append(delta)
                continue
            }
            // Also check nested content delta
            if let delta = event["delta"] as? [String: Any],
               let text = delta["text"] as? String {
                textParts.append(text)
                continue
            }
            // Completed event with output_text
            if let outputText = event["output_text"] as? String,
               !outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return outputText
            }
            // Check for response.completed with full output
            if let output = event["output"] as? [[String: Any]] {
                let texts = output.compactMap { item -> String? in
                    if let content = item["content"] as? [[String: Any]] {
                        return content.compactMap { $0["text"] as? String }.joined()
                    }
                    return nil
                }
                let joined = texts.joined()
                if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return joined
                }
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
