import XCTest
@testable import OpenAssist

final class ToolPermissionRegistryTests: XCTestCase {
    func testComputerUseVerifyFailsWhenOpenAIConnectionIsMissing() {
        let snapshot = ToolPermissionRegistry.PermissionSnapshot(
            accessibilityGranted: true,
            screenRecordingGranted: true,
            appleEventsGranted: false,
            appleEventsKnown: true,
            fullDiskAccessGranted: false,
            browserAutomationEnabled: true,
            browserProfileSelected: true,
            openAIConnectionAvailable: false
        )

        let verdict = ToolPermissionRegistry.verify(
            toolName: AssistantComputerUseToolDefinition.name,
            arguments: ["task": "Type hello into Codex"],
            snapshot: snapshot
        )

        XCTAssertFalse(verdict.satisfied)
        XCTAssertEqual(verdict.missing, [.openAIConnection])
        XCTAssertTrue(verdict.message.contains("OpenAI Connection"))
    }

    func testComputerUseVerifyPassesWhenRequiredInputsAreAvailable() {
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
            toolName: AssistantComputerUseToolDefinition.name,
            arguments: ["task": "Type hello into Codex"],
            snapshot: snapshot
        )

        XCTAssertTrue(verdict.satisfied)
        XCTAssertTrue(verdict.missing.isEmpty)
    }
}
