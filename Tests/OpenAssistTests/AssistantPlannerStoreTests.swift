import Foundation
import XCTest
@testable import OpenAssist

final class AssistantPlannerStoreTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testCreatesPlannerDayFromTemplateUnderDatePath() throws {
        let store = try makeStore()
        let day = try store.loadDay(dayID: "2026-05-24")

        XCTAssertEqual(day.note.id, "2026-05-24")
        XCTAssertTrue(day.fileURL.path.hasSuffix("/Planner/Daily/2026/05/2026-05-24.md"))
        XCTAssertTrue(day.markdown.contains("# Sunday, May 24, 2026"))
        XCTAssertTrue(day.markdown.contains("> Focus:"))
        XCTAssertFalse(day.markdown.contains("## Top 3"))
        XCTAssertFalse(day.markdown.contains("## Journal"))
        XCTAssertFalse(day.markdown.contains("{{"))
    }

    func testTemplateVariablesRenderWithNeighborDays() throws {
        let store = try makeStore()
        let context = try store.dateContext(for: store.date(from: "2026-05-24"))
        let rendered = AssistantPlannerStore.renderTemplate(
            "{{isoDate}} {{weekday}} {{month}} {{yesterday}} {{tomorrow}}",
            context: context
        )

        XCTAssertEqual(rendered, "2026-05-24 Sunday May 2026-05-23 2026-05-25\n")
    }

    func testDesignMarkdownParsesValidTokensAndWarnsOnInvalidColors() {
        let valid = AssistantPlannerStore.parseDesignMarkdown(
            """
            ---
            name: Calm Planner
            colors:
              accent: "#1F6FEB"
            typography:
              heading:
                family: system
            spacing:
              section: 16
            rounded:
              md: 10
            ---
            Body text
            """
        )

        XCTAssertEqual(valid.name, "Calm Planner")
        XCTAssertEqual(valid.colors["accent"], "#1F6FEB")
        XCTAssertEqual(valid.typography["heading"]?["family"], "system")
        XCTAssertEqual(valid.spacing["section"], "16")
        XCTAssertEqual(valid.rounded["md"], "10")
        XCTAssertNil(valid.warning)

        let invalid = AssistantPlannerStore.parseDesignMarkdown(
            """
            ---
            colors:
              accent: blue
            ---
            """
        )
        XCTAssertTrue(invalid.colors.isEmpty)
        XCTAssertNotNil(invalid.warning)
    }

    func testSchedulingPlacesTasksNotesAndLinksInExpectedSections() throws {
        let store = try makeStore()
        _ = try store.loadDay(dayID: "2026-05-24")

        _ = try store.appendScheduledItem(
            AssistantPlannerScheduleRequest(
                mode: .copy,
                targetDayID: "2026-05-24",
                selectedMarkdown: "- [ ] Follow up",
                sourceTarget: nil,
                sourceTitle: nil,
                sourceTextAfterMove: nil,
                originalDayID: nil
            )
        )
        _ = try store.appendScheduledItem(
            AssistantPlannerScheduleRequest(
                mode: .copy,
                targetDayID: "2026-05-24",
                selectedMarkdown: "Remember this",
                sourceTarget: nil,
                sourceTitle: nil,
                sourceTextAfterMove: nil,
                originalDayID: nil
            )
        )
        _ = try store.appendScheduledItem(
            AssistantPlannerScheduleRequest(
                mode: .link,
                targetDayID: "2026-05-24",
                selectedMarkdown: "",
                sourceTarget: AssistantNoteLinkTarget(ownerKind: .project, ownerID: "PROJECT", noteID: "note-1"),
                sourceTitle: "Architecture notes",
                sourceTextAfterMove: nil,
                originalDayID: nil
            )
        )

        let markdown = try store.loadDay(dayID: "2026-05-24").markdown
        XCTAssertTrue(markdown.range(of: "## Tasks[\\s\\S]*- \\[ \\] Follow up", options: .regularExpression) != nil)
        XCTAssertTrue(markdown.range(of: "## Notes[\\s\\S]*- Remember this", options: .regularExpression) != nil)
        XCTAssertTrue(markdown.range(of: "## Linked Notes[\\s\\S]*\\[Architecture notes\\]\\(oa-note://open\\?", options: .regularExpression) != nil)
        XCTAssertTrue(markdown.contains("<!-- oa:planner"))
    }

    func testSchedulingRemovesEmptyTemplatePlaceholders() throws {
        let store = try makeStore()
        _ = try store.saveDay(
            dayID: "2026-05-24",
            text: """
            # Sunday, May 24, 2026

            > Focus:

            ## Tasks
            - [ ]
            -
            """
        )

        _ = try store.appendScheduledItem(
            AssistantPlannerScheduleRequest(
                mode: .copy,
                targetDayID: "2026-05-24",
                selectedMarkdown: "- [ ] Follow up",
                sourceTarget: nil,
                sourceTitle: nil,
                sourceTextAfterMove: nil,
                originalDayID: nil
            )
        )

        let markdown = try store.loadDay(dayID: "2026-05-24").markdown
        XCTAssertFalse(markdown.range(of: #"(?m)^[-*]\s*(?:\[[ xX]\]\s*)?$"#, options: .regularExpression) != nil)
        XCTAssertTrue(markdown.contains("- [ ] Follow up"))
    }

    func testPreviewApplyFlowAddsContentAfterPrepare() throws {
        let store = try makeStore()
        _ = try store.loadDay(dayID: "2026-05-24")
        let preview = try store.prepareAdd(dayID: "2026-05-24", content: "Preview note")

        XCTAssertFalse(try store.loadDay(dayID: "2026-05-24").markdown.contains("Preview note"))

        _ = try store.applyPreview(id: preview.id)

        XCTAssertTrue(try store.loadDay(dayID: "2026-05-24").markdown.contains("Preview note"))
    }

    @MainActor
    func testPlannerToolPreviewAndApplyFlowRequiresAgenticMode() async throws {
        let store = try makeStore()
        let service = AssistantPlannerToolService(plannerStore: store)
        let prepare = await service.run(
            arguments: [
                "action": "prepare_add",
                "targetDayId": "2026-05-24",
                "content": "Tool preview note",
            ],
            runtimeContext: nil,
            interactionMode: .plan
        )

        XCTAssertTrue(prepare.success)
        let previewID = try XCTUnwrap(jsonObject(from: prepare)["previewID"] as? String)

        let blocked = await service.run(
            arguments: [
                "action": "apply_preview",
                "previewId": previewID,
            ],
            runtimeContext: nil,
            interactionMode: .plan
        )
        XCTAssertFalse(blocked.success)

        let applied = await service.run(
            arguments: [
                "action": "apply_preview",
                "previewId": previewID,
            ],
            runtimeContext: nil,
            interactionMode: .agentic
        )
        XCTAssertTrue(applied.success)
        XCTAssertTrue(try store.loadDay(dayID: "2026-05-24").markdown.contains("Tool preview note"))
    }

    private func makeStore() throws -> AssistantPlannerStore {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return AssistantPlannerStore(
            baseDirectoryURL: try makeTemporaryDirectory(named: "assistant-planner-store"),
            calendar: calendar
        )
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    private func jsonObject(from result: AssistantToolExecutionResult) throws -> [String: Any] {
        let text = try XCTUnwrap(result.contentItems.first?.text)
        let data = try XCTUnwrap(text.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
