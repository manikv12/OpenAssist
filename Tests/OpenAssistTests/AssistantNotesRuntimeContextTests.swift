import XCTest
@testable import OpenAssist

final class AssistantNotesRuntimeContextTests: XCTestCase {
    func testInstructionTextIncludesOpenNoteGuidanceAndWorkspaceInventory() {
        let selectedTarget = AssistantNoteLinkTarget(
            ownerKind: .project,
            ownerID: "project-1",
            noteID: "note-1"
        )
        let context = AssistantNotesRuntimeContext(
            source: .notesWorkspace,
            projectID: "project-1",
            projectName: "Work",
            selectedNoteTarget: selectedTarget,
            selectedNoteTitle: "Todo List",
            defaultScopeDescription: "the whole current project (`Work`) including project notes and linked thread notes",
            workspaceScopeLabel: "the current project notes list",
            workspaceNotes: [
                .init(
                    target: selectedTarget,
                    title: "Todo List",
                    sourceLabel: "Project notes",
                    folderPath: ["Planning", "Quarter 2"],
                    fileName: "todo-list.md",
                    isSelected: true
                ),
                .init(
                    target: AssistantNoteLinkTarget(
                        ownerKind: .project,
                        ownerID: "project-1",
                        noteID: "note-2"
                    ),
                    title: "Weekly Plan",
                    sourceLabel: "Project notes",
                    folderPath: [],
                    fileName: "weekly-plan.md",
                    isSelected: false
                )
            ]
        )

        let text = context.instructionText

        XCTAssertTrue(text.contains("Open note right now: `Todo List` (`note-1`)."))
        XCTAssertTrue(text.contains("Folder: `Planning / Quarter 2`."))
        XCTAssertTrue(text.contains("Saved file: `todo-list.md`."))
        XCTAssertTrue(
            text.contains(
                "Do not ask the user to paste note text, upload a note file, or repeat the note name when the open note already gives enough context."
            )
        )
        XCTAssertTrue(text.contains("Notes currently visible in the current project notes list:"))
        XCTAssertTrue(
            text.contains(
                "- OPEN `Todo List` (`todo-list.md`) from Project notes in folder `Planning / Quarter 2`"
            )
        )
        XCTAssertTrue(text.contains("- `Weekly Plan` (`weekly-plan.md`) from Project notes"))
    }
}
