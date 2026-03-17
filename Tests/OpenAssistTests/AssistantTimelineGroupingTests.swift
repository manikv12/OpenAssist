import XCTest
@testable import OpenAssist

final class AssistantTimelineGroupingTests: XCTestCase {
    func testFormattedActivityDetailPrettyPrintsJSONObject() {
        let formatted = assistantFormattedActivityDetailText("{\"b\":2,\"a\":1}")

        XCTAssertTrue(formatted.contains("\n"))
        XCTAssertTrue(formatted.contains("\"a\""))
        XCTAssertTrue(formatted.contains("\"b\""))
    }

    func testFormattedActivityDetailPrettyPrintsJSONArray() {
        let formatted = assistantFormattedActivityDetailText("[{\"type\":\"text\",\"text\":\"hello\"}]")

        XCTAssertTrue(formatted.contains("["))
        XCTAssertTrue(formatted.contains("\n"))
        XCTAssertTrue(formatted.contains("\"type\""))
    }

    func testFormattedActivityDetailLeavesPlainTextAlone() {
        let formatted = assistantFormattedActivityDetailText("plain tool output")

        XCTAssertEqual(formatted, "plain tool output")
    }

    func testActivityOpenTargetsExtractFilesFromPatchOutput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileURL = root
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("OpenAssist", isDirectory: true)
            .appendingPathComponent("Assistant", isDirectory: true)
            .appendingPathComponent("AssistantWindowView.swift")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("test".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: root) }

        let activity = AssistantActivityItem(
            id: "file-change",
            sessionID: "session-1",
            turnID: "turn-1",
            kind: .fileChange,
            title: "File Changes",
            status: .completed,
            friendlySummary: "Edited files in the workspace.",
            rawDetails: "Success. Updated the following files:\nM Sources/OpenAssist/Assistant/AssistantWindowView.swift\n",
            startedAt: Date(),
            updatedAt: Date(),
            source: .runtime
        )

        let targets = assistantActivityOpenTargets(
            for: activity,
            sessionCWD: root.path
        )

        XCTAssertEqual(targets.map(\.label), ["AssistantWindowView.swift"])
        XCTAssertEqual(targets.first?.kind, .file)
        XCTAssertEqual(targets.first?.url.path, fileURL.path)
    }

    func testActivityOpenTargetsExtractFilesFromCommandText() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileURL = root.appendingPathComponent("README.md")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: root) }

        let activity = AssistantActivityItem(
            id: "command-1",
            sessionID: "session-1",
            turnID: "turn-1",
            kind: .commandExecution,
            title: "Command",
            status: .completed,
            friendlySummary: "Ran a terminal command.",
            rawDetails: "cat README.md",
            startedAt: Date(),
            updatedAt: Date(),
            source: .runtime
        )

        let targets = assistantActivityOpenTargets(
            for: activity,
            sessionCWD: root.path
        )

        XCTAssertEqual(targets.map(\.label), ["README.md"])
        XCTAssertEqual(targets.first?.url.path, fileURL.path)
    }

    func testActivityOpenTargetsBuildSearchURLForWebSearch() {
        let activity = AssistantActivityItem(
            id: "search-1",
            sessionID: "session-1",
            turnID: "turn-1",
            kind: .webSearch,
            title: "Web Search",
            status: .completed,
            friendlySummary: "Searched the web.",
            rawDetails: "codex app server timeline ui",
            startedAt: Date(),
            updatedAt: Date(),
            source: .runtime
        )

        let targets = assistantActivityOpenTargets(for: activity)

        XCTAssertEqual(targets.count, 1)
        XCTAssertEqual(targets.first?.kind, .webSearch)
        XCTAssertTrue(targets.first?.url.absoluteString.contains("google.com/search") == true)
        XCTAssertTrue(targets.first?.url.absoluteString.contains("codex") == true)
    }

    func testActivityImagePreviewsLoadScreenshotFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let imageURL = root.appendingPathComponent("codex-current-screen.png")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pngData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9sX0X3cAAAAASUVORK5CYII=")!
        try pngData.write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: root) }

        let activity = AssistantActivityItem(
            id: "image-view-1",
            sessionID: "session-1",
            turnID: "turn-1",
            kind: .commandExecution,
            title: "Image View",
            status: .completed,
            friendlySummary: "Ran a tool.",
            rawDetails: imageURL.path,
            startedAt: Date(),
            updatedAt: Date(),
            source: .runtime
        )

        let previews = assistantActivityImagePreviews(for: activity)

        XCTAssertEqual(previews.count, 1)
        XCTAssertEqual(previews.first?.url.path, imageURL.path)
        XCTAssertEqual(previews.first?.data, pngData)
    }

    func testActivityImagePreviewsIgnoreNonImageFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileURL = root.appendingPathComponent("notes.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: root) }

        let activity = AssistantActivityItem(
            id: "command-2",
            sessionID: "session-1",
            turnID: "turn-1",
            kind: .commandExecution,
            title: "Command",
            status: .completed,
            friendlySummary: "Ran a terminal command.",
            rawDetails: fileURL.path,
            startedAt: Date(),
            updatedAt: Date(),
            source: .runtime
        )

        XCTAssertTrue(assistantActivityImagePreviews(for: activity).isEmpty)
    }

    func testTimelineImageAttachmentsReturnImagesForMatchingReplyTurn() {
        let imageData = Data([0x01, 0x02, 0x03])
        let items: [AssistantTimelineItem] = [
            .assistantFinal(
                id: "reply-1",
                sessionID: "session-1",
                turnID: "turn-1",
                text: "Here is what I can see on your screen right now.",
                createdAt: Date(),
                isStreaming: false,
                source: .runtime
            ),
            .system(
                sessionID: "session-1",
                turnID: "turn-1",
                text: "Latest screenshot",
                imageAttachments: [imageData],
                source: .runtime
            )
        ]

        let attachments = assistantTimelineImageAttachments(
            matchingReplyText: "Here is what I can see on your screen right now.",
            in: items
        )

        XCTAssertEqual(attachments, [imageData])
    }

    func testTimelineImageAttachmentsIgnoreOlderScreenshotWhenCurrentReplyHasNone() {
        let oldImage = Data([0x0A, 0x0B, 0x0C])
        let items: [AssistantTimelineItem] = [
            .assistantFinal(
                id: "reply-old",
                sessionID: "session-1",
                turnID: "turn-old",
                text: "I checked the old screen.",
                createdAt: Date(),
                isStreaming: false,
                source: .runtime
            ),
            .system(
                sessionID: "session-1",
                turnID: "turn-old",
                text: "Latest screenshot",
                imageAttachments: [oldImage],
                source: .runtime
            ),
            .assistantFinal(
                id: "reply-new",
                sessionID: "session-1",
                turnID: "turn-new",
                text: "That was an older screenshot. I can check again now.",
                createdAt: Date(),
                isStreaming: false,
                source: .runtime
            )
        ]

        let attachments = assistantTimelineImageAttachments(
            matchingReplyText: "That was an older screenshot. I can check again now.",
            in: items
        )

        XCTAssertTrue(attachments.isEmpty)
    }

    func testTimelineImageAttachmentsMatchTruncatedReplyPreview() {
        let imageData = Data([0xAA, 0xBB, 0xCC])
        let fullReply = "I checked your screen again and I can now see the current browser window with the project dashboard open."
        let previewReply = "I checked your screen again and I can now see the current browser window..."
        let items: [AssistantTimelineItem] = [
            .assistantFinal(
                id: "reply-1",
                sessionID: "session-1",
                turnID: "turn-1",
                text: fullReply,
                createdAt: Date(),
                isStreaming: false,
                source: .runtime
            ),
            .system(
                sessionID: "session-1",
                turnID: "turn-1",
                text: "Latest screenshot",
                imageAttachments: [imageData],
                source: .runtime
            )
        ]

        let attachments = assistantTimelineImageAttachments(
            matchingReplyText: previewReply,
            in: items
        )

        XCTAssertEqual(attachments, [imageData])
    }

    func testConsecutiveActivitiesBecomeOneGroupedRenderItem() {
        let startedAt = Date(timeIntervalSince1970: 1_741_400_000)
        let items: [AssistantTimelineItem] = [
            .assistantProgress(
                id: "progress-1",
                sessionID: "session-1",
                text: "I am checking the files now.",
                createdAt: startedAt,
                updatedAt: startedAt,
                isStreaming: false,
                source: .runtime
            ),
            .activity(
                AssistantActivityItem(
                    id: "command-1",
                    sessionID: "session-1",
                    turnID: "turn-1",
                    kind: .commandExecution,
                    title: "Command",
                    status: .completed,
                    friendlySummary: "Ran a terminal command.",
                    rawDetails: "rg --files",
                    startedAt: startedAt.addingTimeInterval(1),
                    updatedAt: startedAt.addingTimeInterval(1),
                    source: .runtime
                )
            ),
            .activity(
                AssistantActivityItem(
                    id: "search-1",
                    sessionID: "session-1",
                    turnID: "turn-1",
                    kind: .webSearch,
                    title: "Web Search",
                    status: .completed,
                    friendlySummary: "Searched the web.",
                    rawDetails: "codex app server timeline ui",
                    startedAt: startedAt.addingTimeInterval(2),
                    updatedAt: startedAt.addingTimeInterval(2),
                    source: .runtime
                )
            ),
            .assistantFinal(
                id: "final-1",
                sessionID: "session-1",
                text: "I found the renderer and the event path.",
                createdAt: startedAt.addingTimeInterval(3),
                updatedAt: startedAt.addingTimeInterval(3),
                isStreaming: false,
                source: .runtime
            )
        ]

        let renderItems = buildAssistantTimelineRenderItems(from: items)

        XCTAssertEqual(renderItems.count, 3)
        XCTAssertEqual(renderItems[0].id, "progress-1")
        XCTAssertEqual(renderItems[2].id, "final-1")

        guard case .activityGroup(let group) = renderItems[1] else {
            return XCTFail("Expected the middle render item to be an activity group.")
        }

        XCTAssertEqual(group.activities.count, 2)
        XCTAssertEqual(group.activities.map(\.id), ["command-1", "search-1"])
    }

    func testSingleActivityStaysAsSingleRenderItem() {
        let startedAt = Date(timeIntervalSince1970: 1_741_400_100)
        let items: [AssistantTimelineItem] = [
            .activity(
                AssistantActivityItem(
                    id: "command-1",
                    sessionID: "session-1",
                    turnID: "turn-1",
                    kind: .commandExecution,
                    title: "Command",
                    status: .completed,
                    friendlySummary: "Ran a terminal command.",
                    rawDetails: "pwd",
                    startedAt: startedAt,
                    updatedAt: startedAt,
                    source: .runtime
                )
            )
        ]

        let renderItems = buildAssistantTimelineRenderItems(from: items)

        XCTAssertEqual(renderItems.count, 1)
        guard case .timeline(let item) = renderItems[0] else {
            return XCTFail("Expected a single activity to stay ungrouped.")
        }
        XCTAssertEqual(item.id, "command-1")
    }

    func testVisibleWindowKeepsNewestRenderItems() {
        let baseDate = Date(timeIntervalSince1970: 1_741_400_200)
        let items = (0..<5).map { index in
            AssistantTimelineItem.assistantFinal(
                id: "final-\(index)",
                sessionID: "session-1",
                text: "Message \(index)",
                createdAt: baseDate.addingTimeInterval(TimeInterval(index)),
                updatedAt: baseDate.addingTimeInterval(TimeInterval(index)),
                isStreaming: false,
                source: .runtime
            )
        }

        let renderItems = buildAssistantTimelineRenderItems(from: items)
        let visibleWindow = assistantTimelineVisibleWindow(from: renderItems, visibleLimit: 2)

        XCTAssertEqual(visibleWindow.count, 2)
        XCTAssertEqual(visibleWindow.map(\.id), ["final-3", "final-4"])
    }

    func testNextVisibleLimitLoadsOlderHistoryInBatchesAndClamps() {
        XCTAssertEqual(
            assistantTimelineNextVisibleLimit(
                currentLimit: 48,
                totalCount: 70,
                batchSize: 24
            ),
            70
        )

        XCTAssertEqual(
            assistantTimelineNextVisibleLimit(
                currentLimit: 12,
                totalCount: 100,
                batchSize: 24
            ),
            36
        )
    }
}
