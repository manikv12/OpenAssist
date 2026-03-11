import XCTest
@testable import OpenAssist

final class AssistantComputerUseServiceTests: XCTestCase {
    func testDynamicToolSpecUsesExpectedComputerUseShape() {
        let spec = AssistantComputerUseToolDefinition.dynamicToolSpec()

        XCTAssertEqual(spec["name"] as? String, "computer_use")
        XCTAssertEqual(spec["description"] as? String, AssistantComputerUseToolDefinition.description)

        let schema = spec["inputSchema"] as? [String: Any]
        XCTAssertEqual(schema?["type"] as? String, "object")

        let required = schema?["required"] as? [String]
        XCTAssertEqual(required, ["task"])
    }

    func testParseTaskAcceptsDictionaryAliases() throws {
        let parsed = try AssistantComputerUseService.parseTask(from: [
            "goal": "Check the top message in Mail.",
            "application": "Mail",
            "context": "The user asked for the latest message."
        ])

        XCTAssertEqual(parsed.task, "Check the top message in Mail.")
        XCTAssertEqual(parsed.appHint, "Mail")
        XCTAssertEqual(parsed.reason, "The user asked for the latest message.")
    }

    func testToolPayloadUsesComputerScreenshotOutputFormat() {
        let payload = AssistantComputerUseService.toolPayload(
            for: "call_123",
            screenshotDataURL: "data:image/png;base64,abc"
        )

        XCTAssertEqual(payload.count, 1)
        XCTAssertEqual(payload.first?["type"] as? String, "computer_call_output")
        XCTAssertEqual(payload.first?["call_id"] as? String, "call_123")

        let output = payload.first?["output"] as? [String: Any]
        XCTAssertEqual(output?["type"] as? String, "computer_screenshot")
        XCTAssertEqual(output?["image_url"] as? String, "data:image/png;base64,abc")
    }

    func testExtractOutputTextReadsNestedResponseContent() {
        let text = AssistantComputerUseService.extractOutputText(from: [
            "output": [
                [
                    "content": [
                        ["text": "Opened Mail"],
                        ["text": "Latest message is from Alex"]
                    ]
                ],
                [
                    "text": "No reply sent."
                ]
            ]
        ])

        XCTAssertEqual(
            text,
            """
            Opened Mail
            Latest message is from Alex
            No reply sent.
            """
        )
    }

    func testResponsesEndpointAppendsResponsesPath() {
        XCTAssertEqual(
            AssistantComputerUseService.responsesEndpointStringForTesting(from: "https://api.openai.com/v1"),
            "https://api.openai.com/v1/responses"
        )
        XCTAssertEqual(
            AssistantComputerUseService.responsesEndpointStringForTesting(from: "https://api.openai.com/v1/responses"),
            "https://api.openai.com/v1/responses"
        )
    }

    func testResponsesEndpointRejectsMalformedBaseURL() {
        XCTAssertNil(
            AssistantComputerUseService.responsesEndpointStringForTesting(from: "not a valid url")
        )
    }
}
