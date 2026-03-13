import XCTest
@testable import OpenAssist

final class PromptRewriteStreamingPreviewTests: XCTestCase {
    func testPartialSuggestionPreviewExtractsGrowingSuggestedText() {
        let preview = PromptRewriteService.streamingSuggestionPreview(
            from: #"{"suggested_text":"Please fix this sent"}"#
        )

        XCTAssertEqual(preview, "Please fix this sent")
    }

    func testPartialSuggestionPreviewIgnoresWrapperOnlyJSON() {
        let preview = PromptRewriteService.streamingSuggestionPreview(
            from: #"{"should_rewrite":true,"memory_context":"notes"}"#
        )

        XCTAssertNil(preview)
    }

    func testPartialSuggestionPreviewFallsBackToPlainTextChunks() {
        let preview = PromptRewriteService.streamingSuggestionPreview(
            from: "Please rewrite this into a shorter sentence"
        )

        XCTAssertEqual(preview, "Please rewrite this into a shorter sentence")
    }
}
