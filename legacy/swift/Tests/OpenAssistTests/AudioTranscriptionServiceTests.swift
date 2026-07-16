import Foundation
import XCTest
@testable import OpenAssist

final class AudioTranscriptionServiceTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.handler = nil
        super.tearDown()
    }

    func testOpenAICompatibleRequestParsesTextResponse() async throws {
        let session = makeStubbedSession { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/audio/transcriptions")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.contains("multipart/form-data") == true)

            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"text":"hello from audio"}"#.utf8)
            )
        }

        let service = AudioTranscriptionService(
            session: session,
            codexSessionAuthContextProvider: { _ in
                throw AudioTranscriptionServiceError.sessionUnavailable("unused in this test")
            }
        )
        let result = try await service.transcribe(
            upload: AudioTranscriptionUpload(
                fileData: Data("wave".utf8),
                fileName: "audio.wav",
                mimeType: "audio/wav"
            ),
            configuration: AudioTranscriptionRequestConfiguration(
                provider: .openAI,
                model: "gpt-4o-mini-transcribe",
                baseURL: "https://api.openai.com/v1",
                apiKey: "test-key",
                requestTimeoutSeconds: 10,
                biasPhrases: []
            )
        )

        XCTAssertEqual(result, "hello from audio")
    }

    func testOpenAICompatibleRequestParsesTranscriptFallbackField() async throws {
        let session = makeStubbedSession { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"transcript":"fallback transcript"}"#.utf8)
            )
        }

        let service = AudioTranscriptionService(
            session: session,
            codexSessionAuthContextProvider: { _ in
                throw AudioTranscriptionServiceError.sessionUnavailable("unused in this test")
            }
        )
        let result = try await service.transcribe(
            upload: AudioTranscriptionUpload(
                fileData: Data("wave".utf8),
                fileName: "audio.wav",
                mimeType: "audio/wav"
            ),
            configuration: AudioTranscriptionRequestConfiguration(
                provider: .openAI,
                model: "gpt-4o-mini-transcribe",
                baseURL: "https://api.openai.com/v1",
                apiKey: "test-key",
                requestTimeoutSeconds: 10,
                biasPhrases: []
            )
        )

        XCTAssertEqual(result, "fallback transcript")
    }

    func testCodexSessionUsesDedicatedAuthContextProvider() async throws {
        let tracker = AuthContextRequestTracker()
        let session = makeStubbedSession { request in
            XCTAssertEqual(request.url?.absoluteString, "https://chatgpt.com/backend-api/transcribe")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer codex-session-token")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.contains("multipart/form-data") == true)

            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"text":"hello from codex session"}"#.utf8)
            )
        }

        let service = AudioTranscriptionService(
            session: session,
            codexSessionAuthContextProvider: { refreshToken in
                await tracker.record(refreshToken)
                return CodexTranscriptionAuthContext(
                    authMode: .chatGPT,
                    token: "codex-session-token"
                )
            }
        )

        let result = try await service.transcribe(
            upload: AudioTranscriptionUpload(
                fileData: Data("wave".utf8),
                fileName: "audio.wav",
                mimeType: "audio/wav"
            ),
            configuration: AudioTranscriptionRequestConfiguration(
                provider: .codexSession,
                model: "gpt-4o-mini-transcribe",
                baseURL: "https://ignored.example.com",
                apiKey: "",
                requestTimeoutSeconds: 10,
                biasPhrases: []
            )
        )

        let refreshCalls = await tracker.snapshot()
        XCTAssertEqual(result, "hello from codex session")
        XCTAssertEqual(refreshCalls, [true])
    }

    private func makeStubbedSession(
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        URLProtocolStub.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }
}

private actor AuthContextRequestTracker {
    private var values: [Bool] = []

    func record(_ value: Bool) {
        values.append(value)
    }

    func snapshot() -> [Bool] {
        values
    }
}

private final class URLProtocolStub: URLProtocol, @unchecked Sendable {
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
