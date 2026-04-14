import XCTest
@testable import OpenAssist

final class AssistantStreamingDeltaWhitespaceTests: XCTestCase {
    func testStreamingDeltaPreservesSingleSpace() {
        XCTAssertEqual(" ".streamingDeltaPreservingWhitespace, " ")
    }

    func testStreamingDeltaPreservesNewlines() {
        XCTAssertEqual("\n\n".streamingDeltaPreservingWhitespace, "\n\n")
    }

    func testStreamingDeltaRejectsOnlyEmptyString() {
        XCTAssertNil("".streamingDeltaPreservingWhitespace)
    }
}
