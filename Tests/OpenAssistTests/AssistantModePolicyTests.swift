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
        XCTAssertEqual(
            AssistantModePolicy.commandSafetyClass(for: #"/bin/zsh -lc "rg -n \"plan mode\" Sources""#),
            .readOnly
        )
        XCTAssertEqual(
            AssistantModePolicy.commandSafetyClass(for: "bash -lc 'git diff --stat'"),
            .readOnly
        )
        XCTAssertEqual(
            AssistantModePolicy.commandSafetyClass(
                for: #"/bin/zsh -lc "find /Users/manikvashith -maxdepth 4 -type d \( -iname 'OpenAssist' -o -iname 'open assist' -o -iname '*openassist*' -o -iname '*open-assist*' \) 2>/dev/null""#
            ),
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
        XCTAssertEqual(
            AssistantModePolicy.commandSafetyClass(for: #"/bin/zsh -lc "swift test""#),
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
        XCTAssertEqual(
            AssistantModePolicy.commandSafetyClass(for: #"/bin/zsh -lc "rm -rf tmp""#),
            .mutatingOrUnknown
        )
        XCTAssertEqual(
            AssistantModePolicy.commandSafetyClass(for: #"/bin/zsh -lc "rg todo Sources > results.txt""#),
            .mutatingOrUnknown
        )
        XCTAssertEqual(
            AssistantModePolicy.commandSafetyClass(for: #"/bin/zsh -lc "find Sources 2> results.txt""#),
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
        XCTAssertTrue(
            AssistantModePolicy.shouldAutoApproveCommandRequest(
                mode: .plan,
                command: #"/bin/zsh -lc "rg --files Sources""#
            )
        )
        XCTAssertTrue(
            AssistantModePolicy.shouldAutoApproveCommandRequest(
                mode: .plan,
                command: #"/bin/zsh -lc "find /Users/manikvashith -maxdepth 4 -type d -iname 'OpenAssist' 2>/dev/null""#
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
        XCTAssertTrue(
            AssistantModePolicy.isAllowed(
                mode: .plan,
                activityKind: .commandExecution,
                command: #"/bin/zsh -lc "rg --files Sources""#
            )
        )
        XCTAssertTrue(
            AssistantModePolicy.isAllowed(
                mode: .plan,
                activityKind: .commandExecution,
                command: #"/bin/zsh -lc "find /Users/manikvashith -maxdepth 4 -type d -iname 'OpenAssist' 2>/dev/null""#
            )
        )
        XCTAssertTrue(
            AssistantModePolicy.isAllowed(
                mode: .plan,
                activityKind: .fileChange
            )
        )
        XCTAssertTrue(
            AssistantModePolicy.isAllowed(
                mode: .plan,
                activityKind: .browserAutomation
            )
        )
        XCTAssertTrue(
            AssistantModePolicy.isAllowed(
                mode: .plan,
                activityKind: .dynamicToolCall,
                toolName: "computer_use"
            )
        )
        XCTAssertTrue(
            AssistantModePolicy.isAllowed(
                mode: .plan,
                activityKind: .dynamicToolCall,
                toolName: "browser_use"
            )
        )
        XCTAssertTrue(
            AssistantModePolicy.isAllowed(
                mode: .plan,
                activityKind: .dynamicToolCall,
                toolName: "app_action"
            )
        )
        XCTAssertTrue(
            AssistantModePolicy.isAllowed(
                mode: .plan,
                activityKind: .mcpToolCall
            )
        )
        XCTAssertTrue(
            AssistantModePolicy.isAllowed(
                mode: .plan,
                activityKind: .subagent
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
        XCTAssertFalse(
            AssistantModePolicy.isAllowed(
                mode: .conversational,
                activityKind: .dynamicToolCall,
                toolName: "browser_use"
            )
        )
        XCTAssertFalse(
            AssistantModePolicy.isAllowed(
                mode: .conversational,
                activityKind: .dynamicToolCall,
                toolName: "app_action"
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
