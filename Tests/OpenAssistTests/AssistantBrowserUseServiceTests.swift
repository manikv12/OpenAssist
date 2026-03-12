import XCTest
@testable import OpenAssist

final class AssistantBrowserUseServiceTests: XCTestCase {
    func testParseTaskDoesNotInventURLFromPlainLanguage() throws {
        let parsed = try AssistantBrowserUseService.parseTask(from: [
            "task": "Open the team board in Edge."
        ])

        XCTAssertNil(parsed.requestedURL)
        XCTAssertEqual(parsed.summaryLine, "Open the team board in Edge.")
    }

    func testParseTaskStillAcceptsBareDomains() throws {
        let parsed = try AssistantBrowserUseService.parseTask(from: [
            "task": "Open openai.com in Edge."
        ])

        XCTAssertEqual(parsed.requestedURL?.host, "openai.com")
    }
}
