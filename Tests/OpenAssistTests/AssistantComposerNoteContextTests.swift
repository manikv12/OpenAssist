import XCTest
@testable import OpenAssist

final class AssistantComposerNoteContextTests: XCTestCase {
    func testAutoAttachPolicyAttachesForExplicitOpenNoteRequests() {
        XCTAssertTrue(
            AssistantComposerNoteContentPolicy.shouldAutoAttachContent(
                prompt: "Make a chart of BTC price into this note using Alpaca"
            )
        )
        XCTAssertTrue(
            AssistantComposerNoteContentPolicy.shouldAutoAttachContent(
                prompt: "Summarize the open note"
            )
        )
        XCTAssertTrue(
            AssistantComposerNoteContentPolicy.shouldAutoAttachContent(
                prompt: "Please organize this note"
            )
        )
    }

    func testAutoAttachPolicyDoesNotAttachForUnrelatedPrompts() {
        XCTAssertFalse(
            AssistantComposerNoteContentPolicy.shouldAutoAttachContent(
                prompt: "What is the BTC price today?"
            )
        )
        XCTAssertFalse(
            AssistantComposerNoteContentPolicy.shouldAutoAttachContent(
                prompt: "Open the browser and search for documentation"
            )
        )
        XCTAssertFalse(
            AssistantComposerNoteContentPolicy.shouldAutoAttachContent(
                prompt: "Review the pull request"
            )
        )
        XCTAssertFalse(
            AssistantComposerNoteContentPolicy.shouldAutoAttachContent(
                prompt: "Summarize today's market news"
            )
        )
        XCTAssertFalse(
            AssistantComposerNoteContentPolicy.shouldAutoAttachContent(
                prompt: "Organize project tasks by owner"
            )
        )
    }

    func testManagedProjectNoteContextSerializesProjectFields() {
        let context = AssistantComposerWebNoteContext(
            noteTitle: "Roadmap",
            projectTitle: "OpenAssist",
            ownerKind: "project",
            ownerID: "project-1",
            noteID: "note-1",
            contextKey: "project|project-1|note-1",
            sourceLabel: "Project notes",
            filePath: nil,
            includeContent: true
        )

        let json = context.toJSON()

        XCTAssertEqual(json["noteTitle"] as? String, "Roadmap")
        XCTAssertEqual(json["projectTitle"] as? String, "OpenAssist")
        XCTAssertEqual(json["ownerKind"] as? String, "project")
        XCTAssertEqual(json["ownerId"] as? String, "project-1")
        XCTAssertEqual(json["noteId"] as? String, "note-1")
        XCTAssertEqual(json["contextKey"] as? String, "project|project-1|note-1")
        XCTAssertEqual(json["sourceLabel"] as? String, "Project notes")
        XCTAssertEqual(json["includeContent"] as? Bool, true)
        XCTAssertNil(json["filePath"])
    }

    func testManagedThreadNoteContextSerializesThreadFields() {
        let context = AssistantComposerWebNoteContext(
            noteTitle: "Session Notes",
            projectTitle: "OpenAssist",
            ownerKind: "thread",
            ownerID: "thread-1",
            noteID: "note-2",
            contextKey: "thread|thread-1|note-2",
            sourceLabel: "Thread notes",
            filePath: nil,
            includeContent: false
        )

        let json = context.toJSON()

        XCTAssertEqual(json["ownerKind"] as? String, "thread")
        XCTAssertEqual(json["ownerId"] as? String, "thread-1")
        XCTAssertEqual(json["noteId"] as? String, "note-2")
        XCTAssertEqual(json["sourceLabel"] as? String, "Thread notes")
        XCTAssertEqual(json["includeContent"] as? Bool, false)
    }

    func testExternalMarkdownContextSerializesFileContextWithoutManagedIDs() {
        let context = AssistantComposerWebNoteContext(
            noteTitle: "notes.md",
            projectTitle: "OpenAssist",
            ownerKind: nil,
            ownerID: nil,
            noteID: nil,
            contextKey: "externalMarkdownFile|/tmp/notes.md",
            sourceLabel: "Markdown file",
            filePath: "/tmp/notes.md",
            includeContent: false
        )

        let json = context.toJSON()

        XCTAssertEqual(json["noteTitle"] as? String, "notes.md")
        XCTAssertEqual(json["contextKey"] as? String, "externalMarkdownFile|/tmp/notes.md")
        XCTAssertEqual(json["sourceLabel"] as? String, "Markdown file")
        XCTAssertEqual(json["filePath"] as? String, "/tmp/notes.md")
        XCTAssertNil(json["ownerKind"])
        XCTAssertNil(json["ownerId"])
        XCTAssertNil(json["noteId"])
    }
}
