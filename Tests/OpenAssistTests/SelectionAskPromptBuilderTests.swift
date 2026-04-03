import XCTest
@testable import OpenAssist

final class SelectionAskPromptBuilderTests: XCTestCase {
    func testQuestionPromptIncludesWholeChatHistoryAndReplySuggestions() {
        let prompt = SelectionAskPromptBuilder.makePrompt(
            selectedText: "I am not sure this design is future-proof.",
            parentMessageText: "The current design may work now, but it could become hard to scale later.",
            question: "What should I say back?",
            conversationHistory: [
                SelectionAskConversationTurn(role: .user, text: "What does future-proof mean here?"),
                SelectionAskConversationTurn(role: .assistant, text: "It means the design should still work well as the app grows.")
            ],
            wholeChatSummary: """
            # Recent Chat Context
            - User: Can we keep this simple for now?
            - Assistant: Yes, but we should avoid choices that create bigger cleanup work later.
            """
        )

        XCTAssertTrue(prompt.systemPrompt.contains("You could reply:"))
        XCTAssertTrue(prompt.userPrompt.contains("Recent chat context:"))
        XCTAssertTrue(prompt.userPrompt.contains("Previous side-assistant conversation:"))
        XCTAssertTrue(prompt.userPrompt.contains("User: What does future-proof mean here?"))
        XCTAssertTrue(prompt.userPrompt.contains("Assistant: It means the design should still work well as the app grows."))
        XCTAssertTrue(prompt.userPrompt.contains("Nearby message context:"))
    }

    func testExplainPromptStaysFocusedOnSelectedText() {
        let prompt = SelectionAskPromptBuilder.makePrompt(
            selectedText: "Use shared IDs and clear contracts.",
            parentMessageText: "Modules can talk through shared IDs and clear contracts."
        )

        XCTAssertTrue(prompt.systemPrompt.contains("You explain selected text in simple terms"))
        XCTAssertFalse(prompt.systemPrompt.contains("You could reply:"))
        XCTAssertFalse(prompt.userPrompt.contains("Recent chat context:"))
        XCTAssertFalse(prompt.userPrompt.contains("Previous side-assistant conversation:"))
    }

    func testQuestionPromptIncludesProvidedMainChatSummary() {
        let mainChatSummary = """
        # Recent Chat Context
        - User: We should answer carefully.
        - Assistant: Important ending context for the latest reply.
        """

        let prompt = SelectionAskPromptBuilder.makePrompt(
            selectedText: "We should answer carefully.",
            parentMessageText: "The teammate is asking what to say next.",
            question: "Can you suggest a reply?",
            wholeChatSummary: mainChatSummary
        )

        XCTAssertTrue(prompt.userPrompt.contains("Recent chat context:"))
        XCTAssertTrue(prompt.userPrompt.contains("Important ending context for the latest reply."))
    }

    func testQuestionPromptUsesFocusedParentMessageContext() {
        let prompt = SelectionAskPromptBuilder.makePrompt(
            selectedText: "labels can be changed later",
            parentMessageText: """
            Pulumi returns outputs, and GitHub handles sequencing. labels can be changed later, but snapshots are immutable and safer for exact deployments.
            """,
            question: "Why does this matter?"
        )

        XCTAssertTrue(prompt.userPrompt.contains("Nearby message context:"))
        XCTAssertTrue(prompt.userPrompt.contains("GitHub handles sequencing"))
        XCTAssertTrue(prompt.userPrompt.contains("snapshots are immutable"))
        XCTAssertFalse(
            prompt.systemPrompt.contains(
                #"End with a short section exactly titled "You could reply:""#
            )
        )
    }

    func testQuestionPromptAddsReplySuggestionsOnlyForReplyStyleQuestions() {
        let prompt = SelectionAskPromptBuilder.makePrompt(
            selectedText: "This sounds right.",
            parentMessageText: "We agree with the direction, but we need a short answer back.",
            question: "What should I say back?"
        )

        XCTAssertTrue(prompt.systemPrompt.contains("You could reply:"))
    }

    func testChatSummaryBuilderCreatesCompactMainChatSummary() {
        let snapshot = SelectionSideAssistantChatSummaryBuilder.build(
            sessionID: "thread-1",
            sessionTitle: "Design Chat",
            sessionSummary: "The team is deciding how to scale the app.",
            transcriptEntries: [
                AssistantTranscriptEntry(role: .system, text: "Ignored"),
                AssistantTranscriptEntry(role: .user, text: "Can we keep the first version simple?"),
                AssistantTranscriptEntry(role: .assistant, text: "Yes, but we should avoid choices that create cleanup later."),
                AssistantTranscriptEntry(role: .tool, text: "Ignored tool output")
            ]
        )

        XCTAssertEqual(snapshot?.fingerprint.count, 16)
        XCTAssertTrue(snapshot?.summary.contains("# Recent Chat Context") == true)
        XCTAssertTrue(snapshot?.summary.contains("User: Can we keep the first version simple?") == true)
        XCTAssertTrue(snapshot?.summary.contains("Assistant: Yes, but we should avoid choices that create cleanup later.") == true)
        XCTAssertFalse(snapshot?.summary.contains("Ignored tool output") == true)
    }

    func testChatSummaryBuilderKeepsOnlyMostRecentTurns() {
        let entries: [AssistantTranscriptEntry] = [
            AssistantTranscriptEntry(role: .user, text: "Turn 1"),
            AssistantTranscriptEntry(role: .assistant, text: "Turn 2"),
            AssistantTranscriptEntry(role: .user, text: "Turn 3"),
            AssistantTranscriptEntry(role: .assistant, text: "Turn 4"),
            AssistantTranscriptEntry(role: .user, text: "Turn 5"),
            AssistantTranscriptEntry(role: .assistant, text: "Turn 6"),
            AssistantTranscriptEntry(role: .user, text: "Turn 7"),
            AssistantTranscriptEntry(role: .assistant, text: "Turn 8")
        ]

        let snapshot = SelectionSideAssistantChatSummaryBuilder.build(
            sessionID: "thread-2",
            sessionTitle: "Ignored when recent turns exist",
            sessionSummary: "Ignored when recent turns exist",
            transcriptEntries: entries
        )

        XCTAssertFalse(snapshot?.summary.contains("Turn 1") == true)
        XCTAssertFalse(snapshot?.summary.contains("Turn 2") == true)
        XCTAssertTrue(snapshot?.summary.contains("Turn 3") == true)
        XCTAssertTrue(snapshot?.summary.contains("Turn 8") == true)
    }


    func testThreadNoteChartPromptChoosesMermaidTypeAndReturnsStrictFormat() {
        let prompt = ThreadNoteChartPromptBuilder.makePrompt(
            selectedText: "Frontend has React, NextJS, Vue, TailwindCSS, and Shadcn UI under the SaaS stack.",
            parentMessageText: "Please show the SaaS stack as a structure with main groups and child items."
        )

        XCTAssertTrue(prompt.systemPrompt.contains("Use only supported Mermaid types."))
        XCTAssertTrue(prompt.systemPrompt.contains("Return exactly:"))
        XCTAssertTrue(prompt.systemPrompt.contains("one Mermaid fenced code block"))
        XCTAssertTrue(prompt.systemPrompt.contains("Prefer a presentation-ready diagram with a clear reading order."))
        XCTAssertTrue(prompt.systemPrompt.contains("For flowcharts, default to a top-to-bottom layout unless another direction is clearly better."))
        XCTAssertTrue(prompt.systemPrompt.contains("Use subgraphs or grouped stages when that makes the chart easier to scan."))
        XCTAssertTrue(prompt.systemPrompt.contains("When color helps clarity, choose a small Mermaid color palette in the chart itself."))
        XCTAssertTrue(prompt.systemPrompt.contains("For flowcharts, you may use classDef, class, style, or linkStyle to separate stages or systems."))
        XCTAssertTrue(prompt.systemPrompt.contains("Keep the palette restrained, usually 2 to 4 colors."))
        XCTAssertTrue(prompt.systemPrompt.contains("For hierarchy or stack breakdowns, prefer mindmap"))
        XCTAssertTrue(prompt.systemPrompt.contains("subgraph Core[\"RAPID Core (shared)\"]"))
        XCTAssertTrue(prompt.systemPrompt.contains("Do not write flowchart subgraph titles like subgraph Core[RAPID Core (shared)]."))
        XCTAssertTrue(prompt.userPrompt.contains("Create the best Mermaid chart"))
        XCTAssertTrue(prompt.userPrompt.contains("Selected text:"))
        XCTAssertTrue(prompt.userPrompt.contains("Full message context:"))
    }

    func testThreadNoteChartPromptRegenerationIncludesCurrentDraftAndStyleRequest() {
        let prompt = ThreadNoteChartPromptBuilder.makePrompt(
            selectedText: "Show the login request flow between the user, app, and identity provider.",
            parentMessageText: "The team wants a simple chart for the sign-in sequence.",
            currentDraft: """
            ## Sign In Flow

            ```mermaid
            flowchart TD
              A[User] --> B[App]
            ```
            """,
            styleInstruction: "Use sequence style and keep it simpler."
        )

        XCTAssertTrue(prompt.userPrompt.contains("Regenerate the chart"))
        XCTAssertTrue(prompt.userPrompt.contains("Current chart draft:"))
        XCTAssertTrue(prompt.userPrompt.contains("Change request:"))
        XCTAssertTrue(prompt.userPrompt.contains("Use sequence style and keep it simpler."))
    }
}
