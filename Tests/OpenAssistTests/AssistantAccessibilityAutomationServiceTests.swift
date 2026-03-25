import XCTest
@testable import OpenAssist

final class AssistantAccessibilityAutomationServiceTests: XCTestCase {
    func testParseInspectRequestUsesDefaults() throws {
        let request = try AssistantAccessibilityAutomationService.parseInspectRequest(
            from: ["app": "Chrome"]
        )

        XCTAssertEqual(request.appName, "Chrome")
        XCTAssertNil(request.windowTitle)
        XCTAssertNil(request.label)
        XCTAssertNil(request.role)
        XCTAssertEqual(request.top, 25)
    }

    func testParseClickRequestNeedsLocator() {
        XCTAssertThrowsError(
            try AssistantAccessibilityAutomationService.parseClickRequest(from: [:])
        )
    }

    func testParseTypeRequestNeedsText() {
        XCTAssertThrowsError(
            try AssistantAccessibilityAutomationService.parseTypeRequest(from: ["label": "Search"])
        )
    }

    func testParsePressKeyRequestCollectsKeys() throws {
        let request = try AssistantAccessibilityAutomationService.parsePressKeyRequest(
            from: ["keys": ["cmd", "l"]]
        )

        XCTAssertEqual(request.keys, ["cmd", "l"])
        XCTAssertEqual(request.summaryLine, "Press cmd + l")
    }
}
