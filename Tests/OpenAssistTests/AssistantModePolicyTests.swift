import XCTest
@testable import OpenAssist

final class AssistantModePolicyTests: XCTestCase {
    func testCommandSafetyClassifiesReadOnlyCommands() {
        XCTAssertEqual(
            AssistantModePolicy.commandSafetyClass(for: "rg --files Sources"),
            .readOnly
        )
        XCTAssertEqual(
            AssistantModePolicy.commandSafetyClass(for: "find Sources -name '*.swift'"),
            .readOnly
        )
        XCTAssertEqual(
            AssistantModePolicy.commandSafetyClass(for: "sed -n '1,20p' README.md"),
            .readOnly
        )
        XCTAssertEqual(
            AssistantModePolicy.commandSafetyClass(for: "git diff --stat"),
            .readOnly
        )
        XCTAssertEqual(
            AssistantModePolicy.commandSafetyClass(for: "plutil -p Info.plist"),
            .readOnly
        )
        XCTAssertEqual(
            AssistantModePolicy.commandSafetyClass(for: "rg TODO Sources | head"),
            .readOnly
        )
        XCTAssertEqual(
            AssistantModePolicy.commandSafetyClass(
                for: "python3 /Users/manikvashith/.codex/skills/obsidian-cli/scripts/obsidian_cli_tool.py summarize --file OpenAssist"
            ),
            .readOnly
        )
        XCTAssertEqual(
            AssistantModePolicy.commandSafetyClass(for: "obsidian search query=OpenAssist"),
            .readOnly
        )
    }

    func testCommandSafetyClassifiesValidationCommands() {
        XCTAssertEqual(
            AssistantModePolicy.commandSafetyClass(for: "swift build"),
            .validation
        )
        XCTAssertEqual(
            AssistantModePolicy.commandSafetyClass(for: "swift test"),
            .validation
        )
        XCTAssertEqual(
            AssistantModePolicy.commandSafetyClass(for: "xcodebuild test -scheme OpenAssist"),
            .validation
        )
    }

    func testCommandSafetyClassifiesMutatingOrUnknownCommands() {
        XCTAssertEqual(
            AssistantModePolicy.commandSafetyClass(for: "rm -rf tmp"),
            .mutatingOrUnknown
        )
        XCTAssertEqual(
            AssistantModePolicy.commandSafetyClass(for: "swift package update"),
            .mutatingOrUnknown
        )
        XCTAssertEqual(
            AssistantModePolicy.commandSafetyClass(for: "find . -delete"),
            .mutatingOrUnknown
        )
        XCTAssertEqual(
            AssistantModePolicy.commandSafetyClass(for: "find . -exec rm {} +"),
            .mutatingOrUnknown
        )
        XCTAssertEqual(
            AssistantModePolicy.commandSafetyClass(for: "plutil -replace Foo -string Bar Info.plist"),
            .mutatingOrUnknown
        )
        XCTAssertEqual(
            AssistantModePolicy.commandSafetyClass(for: "custom-tool --flag"),
            .mutatingOrUnknown
        )
    }

    func testChatAutoApprovesTrustedReadOnlyCommandRequests() {
        XCTAssertTrue(
            AssistantModePolicy.shouldAutoApproveCommandRequest(
                mode: .conversational,
                command: "python3 /Users/manikvashith/.codex/skills/obsidian-cli/scripts/obsidian_cli_tool.py read --file OpenAssist"
            )
        )
        XCTAssertFalse(
            AssistantModePolicy.shouldAutoApproveCommandRequest(
                mode: .conversational,
                command: "swift test"
            )
        )
        XCTAssertFalse(
            AssistantModePolicy.shouldAutoApproveCommandRequest(
                mode: .agentic,
                command: "rg --files Sources"
            )
        )
    }

    func testModePolicyAllowsExpectedActivities() {
        XCTAssertTrue(
            AssistantModePolicy.isAllowed(
                mode: .conversational,
                activityKind: .webSearch
            )
        )
        XCTAssertTrue(
            AssistantModePolicy.isAllowed(
                mode: .conversational,
                activityKind: .commandExecution,
                command: "pwd"
            )
        )
        XCTAssertFalse(
            AssistantModePolicy.isAllowed(
                mode: .conversational,
                activityKind: .commandExecution,
                command: "swift test"
            )
        )
        XCTAssertTrue(
            AssistantModePolicy.isAllowed(
                mode: .plan,
                activityKind: .commandExecution,
                command: "swift test"
            )
        )
        XCTAssertFalse(
            AssistantModePolicy.isAllowed(
                mode: .plan,
                activityKind: .fileChange
            )
        )
        XCTAssertFalse(
            AssistantModePolicy.isAllowed(
                mode: .plan,
                activityKind: .browserAutomation
            )
        )
        XCTAssertFalse(
            AssistantModePolicy.isAllowed(
                mode: .plan,
                activityKind: .dynamicToolCall,
                toolName: "computer_use"
            )
        )
        XCTAssertTrue(
            AssistantModePolicy.isAllowed(
                mode: .plan,
                activityKind: .mcpToolCall
            )
        )
        XCTAssertFalse(
            AssistantModePolicy.isAllowed(
                mode: .conversational,
                activityKind: .browserAutomation
            )
        )
        XCTAssertFalse(
            AssistantModePolicy.isAllowed(
                mode: .conversational,
                activityKind: .mcpToolCall
            )
        )
        XCTAssertFalse(
            AssistantModePolicy.isAllowed(
                mode: .conversational,
                activityKind: .dynamicToolCall,
                toolName: "computer_use"
            )
        )
        XCTAssertTrue(
            AssistantModePolicy.isAllowed(
                mode: .conversational,
                activityKind: .dynamicToolCall,
                toolName: "web_lookup"
            )
        )
        XCTAssertFalse(
            AssistantModePolicy.isAllowed(
                mode: .conversational,
                activityKind: .subagent
            )
        )
        XCTAssertTrue(
            AssistantModePolicy.isAllowed(
                mode: .conversational,
                activityKind: .other
            )
        )
        XCTAssertTrue(
            AssistantModePolicy.isAllowed(
                mode: .agentic,
                activityKind: .fileChange
            )
        )
    }

    func testBlockedCommandTitleUsesTheRealCommandText() {
        XCTAssertEqual(
            AssistantModePolicy.activityTitle(forBlockedCommand: "  swift test  "),
            "swift test"
        )
        XCTAssertEqual(
            AssistantModePolicy.activityTitle(forBlockedCommand: nil),
            "Command"
        )
    }
}
