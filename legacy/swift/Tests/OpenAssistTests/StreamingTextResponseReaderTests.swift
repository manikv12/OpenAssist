import XCTest
@testable import OpenAssist

final class StreamingTextResponseReaderTests: XCTestCase {
    func testExtractTextFromEventPayloadReadsNestedCompletedResponseOutput() {
        let payload: [String: Any] = [
            "type": "response.completed",
            "response": [
                "output": [
                    [
                        "content": [
                            [
                                "type": "output_text",
                                "text": "## Fixed Chart\n\n```mermaid\nflowchart TD\nA[\"Deploy (prod)\"]\n```"
                            ]
                        ]
                    ]
                ]
            ]
        ]

        let extracted = StreamingTextResponseReader.extractText(fromEventPayload: payload)

        XCTAssertEqual(
            extracted,
            "## Fixed Chart\n\n```mermaid\nflowchart TD\nA[\"Deploy (prod)\"]\n```"
        )
    }

    func testExtractTextFromEventPayloadReadsNestedPartText() {
        let payload: [String: Any] = [
            "type": "response.content_part.added",
            "part": [
                "type": "output_text",
                "text": "flowchart TD"
            ]
        ]

        let extracted = StreamingTextResponseReader.extractText(fromEventPayload: payload)

        XCTAssertEqual(extracted, "flowchart TD")
    }
}
