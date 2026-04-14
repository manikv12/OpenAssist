import Foundation
import XCTest
@testable import OpenAssist

final class AssistantOllamaChatServiceTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        AssistantOllamaChatServiceURLProtocolStub.handler = nil
    }

    func testStreamChatPreservesWhitespaceOnlyContentChunks() async throws {
        let responseBody = """
        {"message":{"content":"Hello"},"done":false}
        {"message":{"content":" "},"done":false}
        {"message":{"content":"world"},"done":false}
        {"message":{"content":"\\n\\n"},"done":false}
        {"message":{"content":"Next"},"prompt_eval_count":3,"eval_count":4,"done":true}
        """

        let session = makeSession { request in
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "http://127.0.0.1:11434/api/chat")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/x-ndjson"]
            )!
            return (response, Data(responseBody.utf8))
        }

        let service = AssistantOllamaChatService(
            session: session,
            endpoint: URL(string: "http://127.0.0.1:11434/api/chat")!
        )
        let recorder = OllamaStreamDeltaRecorder()

        let response = try await service.streamChat(
            request: AssistantOllamaChatRequest(
                model: "gemma4:e2b",
                messages: [
                    AssistantOllamaChatMessage(role: .user, content: "Say hello")
                ],
                tools: []
            ),
            onEvent: { event in
                if case let .assistantTextDelta(delta) = event {
                    await recorder.append(delta)
                }
            }
        )

        let recordedDeltas = await recorder.snapshot()
        XCTAssertEqual(recordedDeltas, ["Hello", " ", "world", "\n\n", "Next"])
        XCTAssertEqual(response.message.content, "Hello world\n\nNext")
        XCTAssertEqual(response.promptEvalCount, 3)
        XCTAssertEqual(response.evalCount, 4)
    }

    func testUnloadModelUsesGenerateEndpointAndImmediateKeepAlive() async throws {
        let session = makeSession { request in
            XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:11434/api/generate")
            XCTAssertEqual(request.httpMethod, "POST")

            let body = try XCTUnwrap(request.httpBody)
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            XCTAssertEqual(payload["model"] as? String, "gemma4:e4b")
            XCTAssertEqual(payload["stream"] as? Bool, false)
            XCTAssertEqual(payload["keep_alive"] as? Int, 0)

            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "http://127.0.0.1:11434/api/generate")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data("{\"done\":true}".utf8))
        }

        let service = AssistantOllamaChatService(
            session: session,
            endpoint: URL(string: "http://127.0.0.1:11434/api/chat")!,
            generateEndpoint: URL(string: "http://127.0.0.1:11434/api/generate")!
        )

        try await service.unloadModel(named: "gemma4:e4b")
    }

    private func makeSession(
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        AssistantOllamaChatServiceURLProtocolStub.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AssistantOllamaChatServiceURLProtocolStub.self]
        return URLSession(configuration: configuration)
    }
}

private actor OllamaStreamDeltaRecorder {
    private var deltas: [String] = []

    func append(_ delta: String) {
        deltas.append(delta)
    }

    func snapshot() -> [String] {
        deltas
    }
}

private final class AssistantOllamaChatServiceURLProtocolStub: URLProtocol, @unchecked Sendable {
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
