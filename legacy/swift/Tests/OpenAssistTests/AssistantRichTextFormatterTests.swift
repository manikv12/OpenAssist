import AppKit
import XCTest
@testable import OpenAssist

final class AssistantRichTextFormatterTests: XCTestCase {
    func testNestedChildListItemUsesDeeperIndentThanParent() {
        let attributed = AssistantRichTextFormatter.attributedText(
            for: """
            1. Parent item
               - Child item
            """,
            mode: .finalMarkdown,
            variant: .chat(textScale: 1.0)
        )

        let rendered = attributed.string as NSString
        let parentRange = rendered.range(of: "1. Parent item")
        let childRange = rendered.range(of: "• Child item")

        XCTAssertNotEqual(parentRange.location, NSNotFound)
        XCTAssertNotEqual(childRange.location, NSNotFound)

        let parentStyle = attributed.attribute(.paragraphStyle, at: parentRange.location, effectiveRange: nil) as? NSParagraphStyle
        let childStyle = attributed.attribute(.paragraphStyle, at: childRange.location, effectiveRange: nil) as? NSParagraphStyle

        XCTAssertNotNil(parentStyle)
        XCTAssertNotNil(childStyle)
        XCTAssertGreaterThan(childStyle?.firstLineHeadIndent ?? 0, parentStyle?.firstLineHeadIndent ?? 0)
        XCTAssertGreaterThan(childStyle?.headIndent ?? 0, parentStyle?.headIndent ?? 0)
    }

    func testOrderedListsKeepCountingAfterNestedChildren() {
        let attributed = AssistantRichTextFormatter.attributedText(
            for: """
            1. Parent item
               - Child item
            1. Next parent
            """,
            mode: .finalMarkdown,
            variant: .chat(textScale: 1.0)
        )

        XCTAssertTrue(attributed.string.contains("2. Next parent"))
    }

    func testStreamingMarkdownModeFormatsBulletLists() {
        let attributed = AssistantRichTextFormatter.attributedText(
            for: """
            - first
            - second
            """,
            mode: .streamingMarkdown,
            variant: .chat(textScale: 1.0)
        )

        XCTAssertTrue(attributed.string.contains("• first"))
        XCTAssertTrue(attributed.string.contains("• second"))
    }

    func testStreamingMarkdownModeKeepsIncompleteCodeFenceContentVisible() {
        let attributed = AssistantRichTextFormatter.attributedText(
            for: """
            ```swift
            print("hello")
            """,
            mode: .streamingMarkdown,
            variant: .chat(textScale: 1.0)
        )

        XCTAssertTrue(attributed.string.contains("SWIFT"))
        XCTAssertTrue(attributed.string.contains("print(\"hello\")"))
    }
}
