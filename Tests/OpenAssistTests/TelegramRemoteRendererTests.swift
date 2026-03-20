import XCTest
@testable import OpenAssist

final class TelegramRemoteRendererTests: XCTestCase {
    func testChunkTextSplitsLongMessageWithoutDroppingContent() {
        let text = Array(repeating: "alpha beta gamma delta", count: 20).joined(separator: "\n")

        let chunks = TelegramRemoteRenderer.chunkText(text, limit: 60)

        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 60 })
        XCTAssertEqual(chunks.joined(separator: " ").replacingOccurrences(of: "\n", with: " "), text.replacingOccurrences(of: "\n", with: " "))
    }

    func testTranscriptPreviewShowsSessionTitleAndRecentMessages() {
        let entries = [
            AssistantTranscriptEntry(role: .user, text: "First question"),
            AssistantTranscriptEntry(role: .assistant, text: "First answer"),
            AssistantTranscriptEntry(role: .user, text: "Second question")
        ]

        let preview = TelegramRemoteRenderer.transcriptPreviewText(
            sessionTitle: "Build Fix",
            entries: entries
        )

        XCTAssertTrue(preview.contains("Session: Build Fix"))
        XCTAssertTrue(preview.contains("You: First question"))
        XCTAssertTrue(preview.contains("Assistant: First answer"))
        XCTAssertTrue(preview.contains("You: Second question"))
    }

    func testStreamMessageUsesAssistantReplyInsteadOfToolNoise() {
        let snapshot = AssistantRemoteSessionSnapshot(
            session: AssistantSessionSummary(
                id: "session-1",
                title: "Bug Hunt",
                source: .appServer,
                status: .active
            ),
            transcriptEntries: [
                AssistantTranscriptEntry(role: .user, text: "Please inspect the logs."),
                AssistantTranscriptEntry(role: .assistant, text: "I am checking the logs now.", isStreaming: true),
                AssistantTranscriptEntry(role: .tool, text: "Ran rg error logs")
            ],
            pendingPermissionRequest: nil,
            hudState: AssistantHUDState(
                phase: .streaming,
                title: "Streaming",
                detail: "Reading new output"
            ),
            hasActiveTurn: true,
            imageDelivery: nil
        )

        let streamText = TelegramRemoteRenderer.streamMessageText(snapshot: snapshot)

        XCTAssertNotNil(streamText)
        XCTAssertEqual(streamText, "I am checking the logs now.")
    }

    func testStreamMessagePrefersAssistantReplyOverTrailingStatus() {
        let snapshot = AssistantRemoteSessionSnapshot(
            session: AssistantSessionSummary(
                id: "session-2",
                title: "Screenshot Review",
                source: .appServer,
                status: .completed
            ),
            transcriptEntries: [
                AssistantTranscriptEntry(role: .user, text: "What is on the screen?"),
                AssistantTranscriptEntry(role: .assistant, text: "I can see Telegram and Codex open on the screen."),
                AssistantTranscriptEntry(role: .status, text: "Codex finished this turn.")
            ],
            pendingPermissionRequest: nil,
            hudState: .idle,
            hasActiveTurn: false,
            imageDelivery: nil
        )

        let streamText = TelegramRemoteRenderer.streamMessageText(snapshot: snapshot)

        XCTAssertEqual(streamText, "I can see Telegram and Codex open on the screen.")
    }

    func testCatchUpSkipsInternalStatusNoise() {
        let snapshot = AssistantRemoteSessionSnapshot(
            session: AssistantSessionSummary(
                id: "session-3",
                title: "Quiet Chat",
                source: .appServer,
                status: .completed
            ),
            transcriptEntries: [
                AssistantTranscriptEntry(role: .user, text: "Show me the latest screenshot"),
                AssistantTranscriptEntry(role: .status, text: "Codex finished this turn."),
                AssistantTranscriptEntry(role: .assistant, text: "Here is the latest screenshot.")
            ],
            pendingPermissionRequest: nil,
            hudState: .idle,
            hasActiveTurn: false,
            imageDelivery: nil
        )

        let catchUp = TelegramRemoteRenderer.catchUpText(snapshot: snapshot)

        XCTAssertNotNil(catchUp)
        XCTAssertFalse(catchUp?.contains("Codex finished this turn.") == true)
        XCTAssertTrue(catchUp?.contains("Here is the latest screenshot.") == true)
    }

    func testStreamMessageDoesNotEmitThinkingBubbleWithoutAssistantText() {
        let snapshot = AssistantRemoteSessionSnapshot(
            session: AssistantSessionSummary(
                id: "session-4",
                title: "Typing Only",
                source: .appServer,
                status: .active
            ),
            transcriptEntries: [
                AssistantTranscriptEntry(role: .user, text: "Check my screen")
            ],
            pendingPermissionRequest: nil,
            hudState: AssistantHUDState(
                phase: .streaming,
                title: "Streaming",
                detail: "Thinking..."
            ),
            hasActiveTurn: true,
            imageDelivery: nil
        )

        let streamText = TelegramRemoteRenderer.streamMessageText(snapshot: snapshot)

        XCTAssertNil(streamText)
    }

    func testRenderMessageConvertsMarkdownToTelegramHTML() {
        let rendered = TelegramRemoteRenderer.renderSingleMessage("""
        **Story Summary**

        Visit [OpenAI](https://openai.com) and check `main.swift`.
        """)

        XCTAssertNotNil(rendered)
        XCTAssertTrue(rendered?.html.contains("<b>Story Summary</b>") == true)
        XCTAssertTrue(rendered?.html.contains("<a href=\"https://openai.com\">OpenAI</a>") == true)
        XCTAssertTrue(rendered?.html.contains("<code>main.swift</code>") == true)
        XCTAssertEqual(
            rendered?.plainText,
            """
            Story Summary

            Visit OpenAI and check main.swift.
            """
        )
    }

    func testRenderMessageUsesPreformattedHTMLForCodeBlocks() {
        let rendered = TelegramRemoteRenderer.renderSingleMessage("""
        ```swift
        let value = 42
        print(value)
        ```
        """)

        XCTAssertNotNil(rendered)
        XCTAssertEqual(
            rendered?.html,
            "<pre><code class=\"language-swift\">let value = 42\nprint(value)</code></pre>"
        )
        XCTAssertEqual(rendered?.plainText, "let value = 42\nprint(value)")
    }

    func testRenderMessageFormatsHeadingsQuotesAndLists() {
        let rendered = TelegramRemoteRenderer.renderSingleMessage("""
        ## Summary

        > Check the logs

        - First item
        - Second **item**
        """)

        XCTAssertNotNil(rendered)
        XCTAssertTrue(rendered?.html.contains("<b>Summary</b>") == true)
        XCTAssertTrue(rendered?.html.contains("<blockquote>Check the logs</blockquote>") == true)
        XCTAssertTrue(rendered?.html.contains("• First item") == true)
        XCTAssertTrue(rendered?.html.contains("• Second <b>item</b>") == true)
    }

    func testRenderMessageKeepsLocalFileLinksReadableWithoutMakingHTMLLink() {
        let rendered = TelegramRemoteRenderer.renderSingleMessage(
            "[Open file](/Users/manikvashith/tmp/example.swift)"
        )

        XCTAssertNotNil(rendered)
        XCTAssertEqual(
            rendered?.html,
            "Open file (/Users/manikvashith/tmp/example.swift)"
        )
        XCTAssertEqual(
            rendered?.plainText,
            "Open file (/Users/manikvashith/tmp/example.swift)"
        )
    }

    func testRenderMessageEscapesRawHTMLInsteadOfPassingItThrough() {
        let rendered = TelegramRemoteRenderer.renderSingleMessage("<script>alert('x')</script>")

        XCTAssertNotNil(rendered)
        XCTAssertEqual(rendered?.html, "<pre>&lt;script&gt;alert('x')&lt;/script&gt;</pre>")
        XCTAssertEqual(rendered?.plainText, "<script>alert('x')</script>")
    }

    func testRenderMessageUsesPreformattedFallbackForMarkdownTables() {
        let rendered = TelegramRemoteRenderer.renderSingleMessage("""
        | Name | Status |
        | --- | --- |
        | Build | Ready |
        """)

        XCTAssertNotNil(rendered)
        XCTAssertEqual(
            rendered?.html,
            "<pre>| Name | Status |\n| --- | --- |\n| Build | Ready |</pre>"
        )
        XCTAssertEqual(
            rendered?.plainText,
            """
            | Name | Status |
            | --- | --- |
            | Build | Ready |
            """
        )
    }

    func testRenderMessageSplitsLongCodeBlocksIntoBalancedHTMLChunks() {
        let renderedChunks = TelegramRemoteRenderer.renderMessage(
            """
            ```swift
            \(Array(repeating: "let value = 42", count: 20).joined(separator: "\n"))
            ```
            """,
            limit: 120
        )

        XCTAssertGreaterThan(renderedChunks.count, 1)
        XCTAssertTrue(renderedChunks.allSatisfy { $0.html.hasPrefix("<pre") && $0.html.hasSuffix("</pre>") })
        XCTAssertTrue(renderedChunks.allSatisfy { max($0.html.count, $0.plainText.count) <= 120 })
    }

    func testTelegramPlainTextStripsMarkdownMarkers() {
        let cleaned = TelegramRemoteRenderer.telegramPlainText("""
        **Story Summary**

        Azure DevOps story `65358`

        [Open file](/tmp/example.swift)
        """)

        XCTAssertEqual(
            cleaned,
            """
            Story Summary

            Azure DevOps story 65358

            Open file (/tmp/example.swift)
            """
        )
    }
}
