import XCTest
@testable import OpenAssist

final class AssistantToolExecutionResultTests: XCTestCase {
    func testContentItemSerializesImageUrlsWithExpectedKeyShape() {
        let item = AssistantToolExecutionResult.ContentItem(
            type: "inputImage",
            text: nil,
            imageURL: "data:image/png;base64,abc"
        )

        let dictionary = item.dictionaryRepresentation()

        XCTAssertEqual(dictionary["type"] as? String, "input_image")
        XCTAssertNil(dictionary["imageUrl"])
        XCTAssertEqual(dictionary["image_url"] as? String, "data:image/png;base64,abc")
    }
}
