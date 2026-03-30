import XCTest
@testable import OpenAssist

final class AssistantMCPServerMainTests: XCTestCase {
    func testExtractFirstBridgeMessageWaitsForDelimiter() {
        let partial = Data("{\"result\":".utf8)
        XCTAssertNil(AssistantMCPServerMain.extractFirstBridgeMessage(from: partial))
    }

    func testExtractFirstBridgeMessageReturnsOnlyFirstDelimitedMessage() {
        let firstMessage = #"{"result":{"isError":false}}"#
        let secondMessage = #"{"result":{"isError":true}}"#
        let buffer = Data("\(firstMessage)\n\(secondMessage)\n".utf8)

        let extracted = AssistantMCPServerMain.extractFirstBridgeMessage(from: buffer)

        XCTAssertEqual(extracted.flatMap { String(data: $0, encoding: .utf8) }, firstMessage)
    }
}
