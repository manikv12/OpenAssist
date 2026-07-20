import XCTest
@testable import OpenAssist

final class AssistantTimelineDetailSanitizerTests: XCTestCase {
    func testSanitizerRemovesDataImageURLsFromDetails() {
        let raw = """
        {"image_url":"data:image/png;base64,\(String(repeating: "A", count: 1_000))","text":"done"}
        """

        let sanitized = AssistantTimelineDetailSanitizer.sanitized(raw)

        XCTAssertNotNil(sanitized)
        XCTAssertFalse(sanitized?.contains("data:image") == true)
        XCTAssertFalse(sanitized?.contains(String(repeating: "A", count: 512)) == true)
        XCTAssertTrue(sanitized?.contains("[image data omitted]") == true)
    }

    func testSanitizerRemovesRawImageBase64Details() {
        let rawPNGBase64 = "iVBOR" + String(repeating: "A", count: 1_000)

        let sanitized = AssistantTimelineDetailSanitizer.sanitized(rawPNGBase64)

        XCTAssertEqual(sanitized, "[image data omitted]")
    }
}
