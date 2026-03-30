import Foundation
import XCTest
@testable import OpenAssist

final class AssistantImageGenerationServiceTests: XCTestCase {
    override func tearDown() {
        AssistantImageGenerationURLProtocolStub.handler = nil
        super.tearDown()
    }

    func testGenerateImageBuildsGeminiRequestAndReturnsImageContentItems() async throws {
        let requestBox = LockedURLRequestBox()
        let session = makeStubbedSession { request in
            requestBox.request = request

            let imageData = Data([0x89, 0x50, 0x4E, 0x47])
            let responseJSON: [String: Any] = [
                "candidates": [[
                    "content": [
                        "parts": [
                            ["text": "Here is your generated image."],
                            [
                                "inlineData": [
                                    "mimeType": "image/png",
                                    "data": imageData.base64EncodedString()
                                ]
                            ]
                        ]
                    ]
                ]]
            ]
            let responseData = try JSONSerialization.data(withJSONObject: responseJSON)
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                responseData
            )
        }

        let service = AssistantImageGenerationService(
            session: session,
            configurationProvider: {
                GeminiImageGenerationConfiguration(
                    apiKey: "test-key",
                    model: "gemini-2.5-flash-image",
                    baseURL: "https://generativelanguage.googleapis.com/v1beta",
                    requestTimeoutSeconds: 30
                )
            }
        )

        let result = await service.run(
            arguments: ["prompt": "Create a playful banana robot mascot"],
            preferredModelID: nil
        )

        let request = try XCTUnwrap(requestBox.request)
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-image:generateContent?key=test-key"
        )
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try XCTUnwrap(request.httpBody ?? readBody(from: request))
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let config = try XCTUnwrap(root["generationConfig"] as? [String: Any])
        XCTAssertEqual(config["responseModalities"] as? [String], ["TEXT", "IMAGE"])

        let contents = try XCTUnwrap(root["contents"] as? [[String: Any]])
        let first = try XCTUnwrap(contents.first)
        let parts = try XCTUnwrap(first["parts"] as? [[String: Any]])
        XCTAssertEqual(parts.first?["text"] as? String, "Create a playful banana robot mascot")

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.summary, "Generated an image with Google Gemini.")
        XCTAssertGreaterThanOrEqual(result.contentItems.count, 2, "Unexpected result: \(result.summary)")
        XCTAssertEqual(result.contentItems.first?.text, "Generated an image with Google Gemini.")
        XCTAssertTrue(result.contentItems.contains(where: { $0.text == "The image tool succeeded." }))
        XCTAssertTrue(result.contentItems.contains(where: { $0.text == "Here is your generated image." }))
        let imageItem = try XCTUnwrap(result.contentItems.first(where: { $0.type == "inputImage" }))
        XCTAssertTrue(imageItem.imageURL?.hasPrefix("data:image/png;base64,") == true)
    }

    func testGenerateImageIncludesReferenceImagePartsWhenAttachmentsArePresent() async throws {
        let requestBox = LockedURLRequestBox()
        let session = makeStubbedSession { request in
            requestBox.request = request

            let imageData = Data([0x89, 0x50, 0x4E, 0x47])
            let responseJSON: [String: Any] = [
                "candidates": [[
                    "content": [
                        "parts": [[
                            "inlineData": [
                                "mimeType": "image/png",
                                "data": imageData.base64EncodedString()
                            ]
                        ]]
                    ]
                ]]
            ]
            let responseData = try JSONSerialization.data(withJSONObject: responseJSON)
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                responseData
            )
        }

        let service = AssistantImageGenerationService(
            session: session,
            configurationProvider: {
                GeminiImageGenerationConfiguration(
                    apiKey: "test-key",
                    model: "gemini-2.5-flash-image",
                    baseURL: "https://generativelanguage.googleapis.com/v1beta",
                    requestTimeoutSeconds: 30
                )
            }
        )

        let referenceImage = AssistantAttachment(
            filename: "reference.png",
            data: Data([0x01, 0x02, 0x03]),
            mimeType: "image/png"
        )

        let result = await service.run(
            arguments: ["prompt": "Match this app icon closely."],
            referenceImages: [referenceImage],
            preferredModelID: nil
        )

        let request = try XCTUnwrap(requestBox.request)
        let body = try XCTUnwrap(request.httpBody ?? readBody(from: request))
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let contents = try XCTUnwrap(root["contents"] as? [[String: Any]])
        let first = try XCTUnwrap(contents.first)
        let parts = try XCTUnwrap(first["parts"] as? [[String: Any]])

        let inlineImagePart = try XCTUnwrap(parts.first?["inline_data"] as? [String: Any])
        XCTAssertEqual(inlineImagePart["mime_type"] as? String, "image/png")
        XCTAssertEqual(inlineImagePart["data"] as? String, Data([0x01, 0x02, 0x03]).base64EncodedString())
        XCTAssertEqual(parts.last?["text"] as? String, "Match this app icon closely.")
        XCTAssertTrue(result.success)
        XCTAssertTrue(result.contentItems.contains(where: { $0.text == "The image tool succeeded." }))
        XCTAssertTrue(
            result.contentItems.contains(where: {
                $0.text == "Used the attached image reference(s) while generating this image."
            })
        )
    }

    func testGenerateImageReturnsHelpfulMessageWhenKeyIsMissing() async {
        let service = AssistantImageGenerationService(
            configurationProvider: {
                GeminiImageGenerationConfiguration(
                    apiKey: "",
                    model: "gemini-2.5-flash-image",
                    baseURL: "https://generativelanguage.googleapis.com/v1beta",
                    requestTimeoutSeconds: 30
                )
            }
        )

        let result = await service.run(
            arguments: ["prompt": "Create a minimalist app logo."],
            preferredModelID: nil
        )

        XCTAssertFalse(result.success)
        XCTAssertEqual(
            result.summary,
            "Set a Google AI Studio API key in AI Studio to use Gemini image generation."
        )
    }

    func testParseRequestRejectsMissingPrompt() {
        XCTAssertThrowsError(
            try AssistantImageGenerationService.parseRequest(from: ["model": "gemini-2.5-flash-image"])
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Image Generation needs a prompt."
            )
        }
    }

    private func makeStubbedSession(
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        AssistantImageGenerationURLProtocolStub.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AssistantImageGenerationURLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    private func readBody(from request: URLRequest) -> Data? {
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }

        let bufferSize = 4_096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var data = Data()
        while stream.hasBytesAvailable {
            let readCount = stream.read(buffer, maxLength: bufferSize)
            if readCount < 0 {
                return nil
            }
            if readCount == 0 {
                break
            }
            data.append(buffer, count: readCount)
        }
        return data.isEmpty ? nil : data
    }
}

private final class LockedURLRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequest: URLRequest?

    var request: URLRequest? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedRequest
        }
        set {
            lock.lock()
            storedRequest = newValue
            lock.unlock()
        }
    }
}

private final class AssistantImageGenerationURLProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
