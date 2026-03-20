import XCTest
@testable import OpenAssist

final class ToolPermissionRegistryTests: XCTestCase {
    func testBrowserUseVerifyFailsWhenBrowserProfileIsMissing() {
        let snapshot = ToolPermissionRegistry.PermissionSnapshot(
            appleEventsGranted: false,
            appleEventsKnown: true,
            fullDiskAccessGranted: false,
            browserAutomationEnabled: true,
            browserProfileSelected: false
        )

        let verdict = ToolPermissionRegistry.verify(
            toolName: AssistantBrowserUseToolDefinition.name,
            arguments: ["task": "Open the current tab"],
            snapshot: snapshot
        )

        XCTAssertFalse(verdict.satisfied)
        XCTAssertEqual(verdict.missing, [.browserProfile])
        XCTAssertTrue(verdict.message.contains("Browser Profile"))
    }

    func testAppActionVerifyPromotesAppleEventsForTerminal() {
        let snapshot = ToolPermissionRegistry.PermissionSnapshot(
            appleEventsGranted: false,
            appleEventsKnown: true,
            fullDiskAccessGranted: false,
            browserAutomationEnabled: false,
            browserProfileSelected: false
        )

        let verdict = ToolPermissionRegistry.verify(
            toolName: AssistantAppActionToolDefinition.name,
            arguments: ["task": "Run git status in Terminal", "app": "Terminal"],
            snapshot: snapshot
        )

        XCTAssertFalse(verdict.satisfied)
        XCTAssertEqual(verdict.missing, [.appleEvents])
        XCTAssertTrue(verdict.message.contains("Automation"))
    }
}
