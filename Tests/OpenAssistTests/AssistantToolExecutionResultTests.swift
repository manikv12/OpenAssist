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

        XCTAssertEqual(dictionary["type"] as? String, "inputImage")
        XCTAssertNil(dictionary["imageUrl"])

        guard let imageURL = dictionary["image_url"] as? [String: Any] else {
            return XCTFail("Expected nested image_url payload")
        }
        XCTAssertEqual(imageURL["url"] as? String, "data:image/png;base64,abc")
    }
}
