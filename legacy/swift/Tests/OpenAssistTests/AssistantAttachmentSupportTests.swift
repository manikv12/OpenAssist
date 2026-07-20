import XCTest
@testable import OpenAssist

final class AssistantAttachmentSupportTests: XCTestCase {
    func testAttachmentFromDataURLKeepsProvidedFilename() {
        let encodedText = Data("hello world".utf8).base64EncodedString()
        let dataURL = "data:text/plain;base64,\(encodedText)"

        let attachment = AssistantAttachmentSupport.attachment(
            fromDataURL: dataURL,
            suggestedFilename: "notes.txt"
        )

        XCTAssertNotNil(attachment)
        XCTAssertEqual(attachment?.filename, "notes.txt")
        XCTAssertEqual(attachment?.mimeType, "text/plain")
        XCTAssertEqual(String(data: attachment?.data ?? Data(), encoding: .utf8), "hello world")
    }

    func testAttachmentFromDataURLAddsMissingExtensionFromMimeType() {
        let dataURL = "data:image/png;base64,\(Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString())"

        let attachment = AssistantAttachmentSupport.attachment(
            fromDataURL: dataURL,
            suggestedFilename: "clipboard-image"
        )

        XCTAssertNotNil(attachment)
        XCTAssertEqual(attachment?.filename, "clipboard-image.png")
        XCTAssertEqual(attachment?.mimeType, "image/png")
        XCTAssertEqual(attachment?.data, Data([0x89, 0x50, 0x4E, 0x47]))
    }
}
