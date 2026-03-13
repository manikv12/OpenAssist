import XCTest
@testable import OpenAssist

final class AssistantTextRenderingPolicyTests: XCTestCase {
    func testPlainMultilineResponseUsesPlainRendering() {
        let style = AssistantTextRenderingPolicy.style(
            for: "first line\nsecond line\nthird line",
            isStreaming: false
        )

        XCTAssertEqual(style, .plain)
    }

    func testStreamingBulletListUsesPlainRendering() {
        let style = AssistantTextRenderingPolicy.style(
            for: "- first\n- second",
            isStreaming: true
        )

        XCTAssertEqual(style, .plain)
    }

    func testBulletListUsesMarkdownRenderingWhenFinalized() {
        let style = AssistantTextRenderingPolicy.style(
            for: "- first\n- second",
            isStreaming: false
        )

        XCTAssertEqual(style, .markdown)
    }

    func testCodeFenceUsesMarkdownRenderingWhenFinalized() {
        let style = AssistantTextRenderingPolicy.style(
            for: "```swift\nprint(\"hello\")\n```",
            isStreaming: false
        )

        XCTAssertEqual(style, .markdown)
    }

    func testStreamingCodeFenceUsesPlainRendering() {
        let style = AssistantTextRenderingPolicy.style(
            for: "```swift\nprint(\"hello\")",
            isStreaming: true
        )

        XCTAssertEqual(style, .plain)
    }

    func testVisibleTextSanitizerRemovesWrappedAnalysisBlock() {
        let cleaned = AssistantVisibleTextSanitizer.clean(
            """
            <analysis>
            hidden thinking
            </analysis>

            Final answer
            """
        )

        XCTAssertEqual(cleaned, "Final answer")
    }

    func testVisibleTextSanitizerPrefersUserFacingPrefixOverScratchpadSuffix() {
        let cleaned = AssistantVisibleTextSanitizer.clean(
            """
            If you want, I can now turn this into a step-by-step checklist.
            </analysis>
            Need ensure no stray text after closing.
            Let's output final.
            """
        )

        XCTAssertEqual(cleaned, "If you want, I can now turn this into a step-by-step checklist.")
    }

    func testVisibleTextSanitizerRemovesImagePlaceholders() {
        let cleaned = AssistantVisibleTextSanitizer.clean(
            """
            <image></image>
            What does the dead letter mean here?
            """
        )

        XCTAssertEqual(cleaned, "What does the dead letter mean here?")
    }
}
