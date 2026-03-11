import XCTest
@testable import OpenAssist

final class TranscriberStatusInterpreterTests: XCTestCase {
    func testReadyMessageStaysPersistent() {
        XCTAssertEqual(
            TranscriberStatusInterpreter.interpret("Ready"),
            .persistent(.ready)
        )
    }

    func testFinalizingMessageStaysPersistent() {
        XCTAssertEqual(
            TranscriberStatusInterpreter.interpret("Finalizing…"),
            .persistent(.finalizing)
        )
    }

    func testCloudFailureBecomesTransientFailure() {
        XCTAssertEqual(
            TranscriberStatusInterpreter.interpret("Cloud transcription failed: The request timed out."),
            .transientFailure(message: "Cloud transcription failed: The request timed out.")
        )
    }

    func testWhisperFailureBecomesTransientFailure() {
        XCTAssertEqual(
            TranscriberStatusInterpreter.interpret("Whisper error: whisper_full failed"),
            .transientFailure(message: "Whisper error: whisper_full failed")
        )
    }
}
