import XCTest
@testable import OpenAssist

final class CloudTranscriberPromptGuardTests: XCTestCase {
    func testPromptEchoIsRejected() {
        XCTAssertTrue(CloudTranscriber.looksLikeTranscriptionPromptEcho("Transcribe this audio."))
        XCTAssertTrue(
            CloudTranscriber.looksLikeTranscriptionPromptEcho(
                "Transcribe this audio verbatim. Preserve wording and punctuation when clear."
            )
        )
    }

    func testNormalTranscriptIsNotRejected() {
        XCTAssertFalse(CloudTranscriber.looksLikeTranscriptionPromptEcho("Can you open Downloads and summarize the files?"))
    }
}
