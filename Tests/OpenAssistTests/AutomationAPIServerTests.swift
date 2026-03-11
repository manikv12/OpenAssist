import Foundation
import XCTest
@testable import OpenAssist

final class AutomationAPIServerTests: XCTestCase {
    func testParseRequestRejectsNegativeContentLength() {
        let request = Data("POST /automation/v1/announce HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: -1\r\n\r\n".utf8)

        XCTAssertThrowsError(
            try LocalAutomationServer.parseRequest(from: request, maximumPayloadSize: 1024)
        ) { error in
            XCTAssertEqual(error as? AutomationAPIHTTPParseError, .invalidContentLength)
        }
    }

    func testParseRequestAcceptsPositiveContentLengthBody() throws {
        let request = Data("POST /automation/v1/announce HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 5\r\n\r\nhello".utf8)

        let parsed = try LocalAutomationServer.parseRequest(from: request, maximumPayloadSize: 1024)
        guard case .complete(let httpRequest) = parsed else {
            return XCTFail("Expected a complete HTTP request.")
        }

        XCTAssertEqual(httpRequest.method, "POST")
        XCTAssertEqual(httpRequest.path, "/automation/v1/announce")
        XCTAssertEqual(String(data: httpRequest.body, encoding: .utf8), "hello")
    }
}
