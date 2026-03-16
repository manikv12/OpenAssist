import XCTest
@testable import OpenAssist

final class ToolPermissionRegistryTests: XCTestCase {
    func testComputerUseMessageIncludesSettingsGuidance() {
        let snapshot = ToolPermissionRegistry.PermissionSnapshot(
            accessibilityGranted: false,
            screenRecordingGranted: false,
            appleEventsGranted: false,
            appleEventsKnown: true,
            fullDiskAccessGranted: false,
            browserAutomationEnabled: false,
            browserProfileSelected: false,
            openAIConnectionAvailable: true
        )

        let verdict = ToolPermissionRegistry.verify(
            toolName: "computer_use",
            arguments: ["task": "Read the screen"],
            snapshot: snapshot
        )

        XCTAssertFalse(verdict.satisfied)
        XCTAssertTrue(verdict.message.contains("Grant Accessibility in Settings > Computer Control."))
        XCTAssertTrue(verdict.message.contains("Grant Screen Recording in Settings > Computer Control."))
    }

    func testBrowserUseMessageIncludesAutomationAndProfileGuidance() {
        let snapshot = ToolPermissionRegistry.PermissionSnapshot(
            accessibilityGranted: true,
            screenRecordingGranted: true,
            appleEventsGranted: false,
            appleEventsKnown: true,
            fullDiskAccessGranted: false,
            browserAutomationEnabled: false,
            browserProfileSelected: false,
            openAIConnectionAvailable: true
        )

        let verdict = ToolPermissionRegistry.verify(
            toolName: "browser_use",
            arguments: ["task": "Read the current tab"],
            snapshot: snapshot
        )

        XCTAssertFalse(verdict.satisfied)
        XCTAssertTrue(verdict.message.contains("Turn on Browser Automation in Settings > Computer Control."))
        XCTAssertTrue(verdict.message.contains("Choose a Browser Profile in Settings > Computer Control."))
    }
}
