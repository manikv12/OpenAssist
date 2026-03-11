import XCTest
@testable import OpenAssist

final class AssistantVoiceDraftRefinementServiceTests: XCTestCase {
    func testDisabledAICorrectionReturnsTrimmedTranscript() async {
        let service = AssistantVoiceDraftRefinementService(
            promptRewriter: StubPromptRewriter(result: .success(nil))
        )

        let refined = await service.refine("  raw transcript  ", aiCorrectionEnabled: false)

        XCTAssertEqual(refined, "raw transcript")
    }

    func testEnabledAICorrectionUsesSuggestedText() async {
        let service = AssistantVoiceDraftRefinementService(
            promptRewriter: StubPromptRewriter(
                result: .success(
                    PromptRewriteSuggestion(
                        suggestedText: "Please clean up my Downloads folder.",
                        memoryContext: nil
                    )
                )
            )
        )

        let refined = await service.refine("please clean up my downloads folder", aiCorrectionEnabled: true)

        XCTAssertEqual(refined, "Please clean up my Downloads folder.")
    }

    func testEnabledAICorrectionFallsBackWhenSuggestionIsEmpty() async {
        let service = AssistantVoiceDraftRefinementService(
            promptRewriter: StubPromptRewriter(
                result: .success(
                    PromptRewriteSuggestion(
                        suggestedText: "   ",
                        memoryContext: nil
                    )
                )
            )
        )

        let refined = await service.refine("keep original wording", aiCorrectionEnabled: true)

        XCTAssertEqual(refined, "keep original wording")
    }

    func testEnabledAICorrectionFallsBackWhenRewriteFails() async {
        let service = AssistantVoiceDraftRefinementService(
            promptRewriter: StubPromptRewriter(
                result: .failure(
                    PromptRewriteServiceError.providerUnavailable(reason: "offline")
                )
            )
        )

        let refined = await service.refine("fallback text", aiCorrectionEnabled: true)

        XCTAssertEqual(refined, "fallback text")
    }
}

private struct StubPromptRewriter: AssistantVoiceDraftPromptRewriting {
    let result: Result<PromptRewriteSuggestion?, Error>

    func retrieveSuggestion(
        for cleanedTranscript: String,
        conversationContext: PromptRewriteConversationContext?,
        conversationHistory: [PromptRewriteConversationTurn]
    ) async throws -> PromptRewriteSuggestion? {
        switch result {
        case .success(let suggestion):
            return suggestion
        case .failure(let error):
            throw error
        }
    }
}
