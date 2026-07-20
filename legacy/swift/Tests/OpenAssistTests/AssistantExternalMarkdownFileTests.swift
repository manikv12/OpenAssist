import XCTest
@testable import OpenAssist

final class AssistantExternalMarkdownFileTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        let fileManager = FileManager.default
        for directory in temporaryDirectories {
            try? fileManager.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testExternalMarkdownFileStateLoadsDraftAndMetadata() throws {
        let directory = try makeTemporaryDirectory(named: "external-markdown-load")
        let fileURL = directory.appendingPathComponent("README.md", isDirectory: false)
        try "# Hello\n\nDraft body".write(to: fileURL, atomically: true, encoding: .utf8)

        let state = try AssistantExternalMarkdownFileState.load(from: fileURL)

        XCTAssertEqual(state.fileURL, fileURL)
        XCTAssertEqual(state.fileName, "README.md")
        XCTAssertEqual(state.filePath, fileURL.path)
        XCTAssertEqual(state.draftText, "# Hello\n\nDraft body")
        XCTAssertEqual(state.savedText, "# Hello\n\nDraft body")
        XCTAssertFalse(state.isDirty)
        XCTAssertTrue(state.canSave)
    }

    func testExternalMarkdownFileStateSavingWritesUpdatedTextAndClearsDirty() throws {
        let directory = try makeTemporaryDirectory(named: "external-markdown-save")
        let fileURL = directory.appendingPathComponent("notes.markdown", isDirectory: false)
        try "Initial".write(to: fileURL, atomically: true, encoding: .utf8)

        let loaded = try AssistantExternalMarkdownFileState.load(from: fileURL)
        let updated = loaded.updatingDraft("Changed body")
        XCTAssertTrue(updated.isDirty)

        let saved = try updated.saving()

        XCTAssertEqual(saved.savedText, "Changed body")
        XCTAssertEqual(saved.draftText, "Changed body")
        XCTAssertFalse(saved.isDirty)
        XCTAssertEqual(
            try String(contentsOf: fileURL, encoding: .utf8),
            "Changed body"
        )
    }

    func testThreadNoteSourceDescriptorSerializesExternalMarkdownMetadata() throws {
        let descriptor = AssistantChatWebThreadNoteSourceDescriptor(
            sourceKind: "externalMarkdownFile",
            filePath: "/tmp/Docs/README.md",
            fileName: "README.md",
            isDirty: true,
            canSave: true
        )

        let json = descriptor.toJSON()

        XCTAssertEqual(json["sourceKind"] as? String, "externalMarkdownFile")
        XCTAssertEqual(json["filePath"] as? String, "/tmp/Docs/README.md")
        XCTAssertEqual(json["fileName"] as? String, "README.md")
        XCTAssertEqual(json["isDirty"] as? Bool, true)
        XCTAssertEqual(json["canSave"] as? Bool, true)
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(name + "-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }
}
