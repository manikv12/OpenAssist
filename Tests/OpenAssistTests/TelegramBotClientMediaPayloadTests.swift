import XCTest
@testable import OpenAssist

final class TelegramBotClientMediaPayloadTests: XCTestCase {
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
}
