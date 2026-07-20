import XCTest
@testable import OpenAssist

final class TelegramBotClientMediaPayloadTests: XCTestCase {
    override func tearDown() {
        TelegramBotClientURLProtocolStub.handler = nil
        super.tearDown()
    }

    func testMessageDecodesVoicePayload() throws {
        let data = Data(
            """
            {
              "message_id": 42,
              "date": 1731120000,
              "chat": { "id": 1001, "type": "private" },
              "voice": {
                "file_id": "voice-file",
                "duration": 7,
                "mime_type": "audio/ogg",
                "file_size": 2048
              }
            }
            """.utf8
        )

        let message = try JSONDecoder().decode(TelegramMessage.self, from: data)

        XCTAssertEqual(message.messageID, 42)
        XCTAssertEqual(message.voice?.fileID, "voice-file")
        XCTAssertEqual(message.voice?.duration, 7)
        XCTAssertEqual(message.voice?.mimeType, "audio/ogg")
        XCTAssertEqual(message.voice?.fileSize, 2048)
    }

    func testMessageDecodesAudioPayload() throws {
        let data = Data(
            """
            {
              "message_id": 43,
              "date": 1731120001,
              "chat": { "id": 1002, "type": "private" },
              "audio": {
                "file_id": "audio-file",
                "duration": 12,
                "file_name": "memo.m4a",
                "mime_type": "audio/m4a",
                "file_size": 4096,
                "title": "Memo"
              }
            }
            """.utf8
        )

        let message = try JSONDecoder().decode(TelegramMessage.self, from: data)

        XCTAssertEqual(message.audio?.fileID, "audio-file")
        XCTAssertEqual(message.audio?.duration, 12)
        XCTAssertEqual(message.audio?.fileName, "memo.m4a")
        XCTAssertEqual(message.audio?.mimeType, "audio/m4a")
        XCTAssertEqual(message.audio?.fileSize, 4096)
        XCTAssertEqual(message.audio?.title, "Memo")
    }

    func testMessageDecodesDocumentPayload() throws {
        let data = Data(
            """
            {
              "message_id": 44,
              "date": 1731120002,
              "chat": { "id": 1003, "type": "private" },
              "document": {
                "file_id": "document-file",
                "file_name": "sample.opus",
                "mime_type": "audio/opus",
                "file_size": 8192
              },
              "caption": "voice upload"
            }
            """.utf8
        )

        let message = try JSONDecoder().decode(TelegramMessage.self, from: data)

        XCTAssertEqual(message.document?.fileID, "document-file")
        XCTAssertEqual(message.document?.fileName, "sample.opus")
        XCTAssertEqual(message.document?.mimeType, "audio/opus")
        XCTAssertEqual(message.document?.fileSize, 8192)
        XCTAssertEqual(message.caption, "voice upload")
    }

    func testSendMessageDraftUsesExpectedPayload() async throws {
        let requestBox = LockedURLRequestBox()
        let client = makeStubbedClient { request in
            requestBox.request = request
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"ok":true,"result":true}"#.utf8)
            )
        }

        let result = try await client.sendMessageDraft(
            chatID: 1001,
            draftID: 77,
            text: "<b>Hello</b>",
            parseMode: .html
        )

        XCTAssertTrue(result)
        let request = try XCTUnwrap(requestBox.request)
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://api.telegram.org/bottest-token/sendMessageDraft"
        )
        let body = try XCTUnwrap(readBody(from: request))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual((json["chat_id"] as? NSNumber)?.int64Value, 1001)
        XCTAssertEqual((json["draft_id"] as? NSNumber)?.intValue, 77)
        XCTAssertEqual(json["text"] as? String, "<b>Hello</b>")
        XCTAssertEqual(json["parse_mode"] as? String, "HTML")
    }

    func testSendMessageCanDisableNotification() async throws {
        let requestBox = LockedURLRequestBox()
        let client = makeStubbedClient { request in
            requestBox.request = request
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(
                    """
                    {"ok":true,"result":{"message_id":55,"date":1731120300,"chat":{"id":1001,"type":"private"},"text":"hello"}}
                    """.utf8
                )
            )
        }

        _ = try await client.sendMessage(
            chatID: 1001,
            text: "hello",
            disableNotification: true
        )

        let request = try XCTUnwrap(requestBox.request)
        let body = try XCTUnwrap(readBody(from: request))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual((json["chat_id"] as? NSNumber)?.int64Value, 1001)
        XCTAssertEqual(json["text"] as? String, "hello")
        XCTAssertEqual(json["disable_notification"] as? Bool, true)
    }

    private func makeStubbedClient(
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> TelegramBotClient {
        TelegramBotClientURLProtocolStub.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TelegramBotClientURLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        return TelegramBotClient(token: "test-token", session: session)
    }

    private func readBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }

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

private final class TelegramBotClientURLProtocolStub: URLProtocol, @unchecked Sendable {
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
