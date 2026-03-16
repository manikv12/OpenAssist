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

    func testShouldReadCurrentTabForCurrentlyOpenBrowserTab() throws {
        let parsed = try AssistantBrowserUseService.parseTask(from: [
            "task": "Check the currently open Brave browser tab and report the visible GitHub release error."
        ])

        XCTAssertTrue(parsed.shouldReadCurrentTab)
    }

    func testShouldReadCurrentTabForActiveBrowserTab() throws {
        let parsed = try AssistantBrowserUseService.parseTask(from: [
            "task": "Read the active Brave tab and summarize what failed on the current GitHub page."
        ])

        XCTAssertTrue(parsed.shouldReadCurrentTab)
    }

    func testShouldReadCurrentTabForTabTitleAndURLRequest() throws {
        let parsed = try AssistantBrowserUseService.parseTask(from: [
            "task": "In the current Brave window, tell me the active tab title and URL if available."
        ])

        XCTAssertTrue(parsed.shouldReadCurrentTab)
    }
}
