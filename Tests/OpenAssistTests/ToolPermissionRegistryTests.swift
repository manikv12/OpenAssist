import XCTest
@testable import OpenAssist

final class ToolPermissionRegistryTests: XCTestCase {
    func testBrowserUseVerifyFailsWhenBrowserProfileIsMissing() {
        let snapshot = ToolPermissionRegistry.PermissionSnapshot(
            accessibilityGranted: false,
            screenRecordingGranted: false,
            appleEventsGranted: false,
            appleEventsKnown: true,
            fullDiskAccessGranted: false,
            browserAutomationEnabled: true,
            browserProfileSelected: false,
            computerUseEnabled: true
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
            accessibilityGranted: false,
            screenRecordingGranted: false,
            appleEventsGranted: false,
            appleEventsKnown: true,
            fullDiskAccessGranted: false,
            browserAutomationEnabled: false,
            browserProfileSelected: false,
            computerUseEnabled: true
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

    func testGenerateImageVerifyRequiresNoMacPermissions() {
        let snapshot = ToolPermissionRegistry.PermissionSnapshot(
            accessibilityGranted: false,
            screenRecordingGranted: false,
            appleEventsGranted: false,
            appleEventsKnown: true,
            fullDiskAccessGranted: false,
            browserAutomationEnabled: false,
            browserProfileSelected: false,
            computerUseEnabled: true
        )

        let verdict = ToolPermissionRegistry.verify(
            toolName: AssistantImageGenerationToolDefinition.name,
            arguments: ["prompt": "Create a clean app icon of a banana robot."],
            snapshot: snapshot
        )

        XCTAssertTrue(verdict.satisfied)
        XCTAssertTrue(verdict.missing.isEmpty)
        XCTAssertEqual(verdict.message, "")
    }

    func testComputerUseVerifyRequiresToggleAndDesktopPermissions() {
        let snapshot = ToolPermissionRegistry.PermissionSnapshot(
            accessibilityGranted: false,
            screenRecordingGranted: false,
            appleEventsGranted: false,
            appleEventsKnown: true,
            fullDiskAccessGranted: false,
            browserAutomationEnabled: false,
            browserProfileSelected: false,
            computerUseEnabled: false
        )

        let verdict = ToolPermissionRegistry.verify(
            toolName: AssistantComputerUseToolDefinition.name,
            arguments: [
                "task": "Click the Filters button.",
                "reason": "Need generic desktop interaction.",
                "action": ["type": "click", "x": 120, "y": 48]
            ],
            snapshot: snapshot
        )

        XCTAssertFalse(verdict.satisfied)
        XCTAssertEqual(
            Set(verdict.missing),
            Set([.computerUseEnabled, .accessibility, .screenRecording])
        )
        XCTAssertTrue(verdict.message.contains("Computer Use"))
        XCTAssertTrue(verdict.message.contains("Accessibility"))
        XCTAssertTrue(verdict.message.contains("Screen Recording"))
    }
}
