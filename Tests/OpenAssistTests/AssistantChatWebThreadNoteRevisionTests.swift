import XCTest
@testable import OpenAssist

final class AssistantChatWebThreadNoteRevisionTests: XCTestCase {
    func testThreadNoteCommandParsesDraftRevision() {
        let command = AssistantChatWebThreadNoteCommand(
            body: [
                "type": "save",
                "requestId": "save-1",
                "draftRevision": NSNumber(value: 42),
                "text": "Updated note body",
            ]
        )

        XCTAssertEqual(command?.type, "save")
        XCTAssertEqual(command?.requestID, "save-1")
        XCTAssertEqual(command?.draftRevision, 42)
        XCTAssertEqual(command?.text, "Updated note body")
    }

    func testThreadNoteSaveAckSerializesDraftRevision() {
        let ack = AssistantChatWebThreadNoteSaveAck(
            requestID: "save-2",
            ownerKind: "project",
            ownerID: "project-1",
            noteID: "note-1",
            draftRevision: 17,
            status: "ok",
            errorMessage: nil
        )

        let json = ack.toJSON()
        XCTAssertEqual(json["requestId"] as? String, "save-2")
        XCTAssertEqual(json["draftRevision"] as? Int, 17)
        XCTAssertEqual(json["status"] as? String, "ok")
    }
}
