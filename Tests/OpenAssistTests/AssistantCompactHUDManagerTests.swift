import XCTest
@testable import OpenAssist

final class AssistantCompactHUDManagerTests: XCTestCase {
    @MainActor
    func testEndedLiveVoiceDoesNotOverrideActiveHUDState() {
        let snapshot = AssistantLiveVoiceSessionSnapshot(
            phase: .ended,
            surface: .compactHUD,
            interactionMode: .agentic,
            isHandsFreeLoopEnabled: false,
            sessionID: "session-1",
            lastTranscript: "Check Obsidian",
            statusMessage: "Live voice ended.",
            lastError: nil,
            permissionRequest: nil
        )
        let hudState = AssistantHUDState(
            phase: .acting,
            title: "Spawning agent",
            detail: "Checking Obsidian"
        )

        XCTAssertFalse(
            AssistantCompactHUDManager.shouldUseLiveVoiceDisplayState(snapshot, over: hudState)
        )
    }

    @MainActor
    func testActiveLiveVoiceStillOverridesHUDState() {
        let snapshot = AssistantLiveVoiceSessionSnapshot(
            phase: .sending,
            surface: .compactHUD,
            interactionMode: .agentic,
            isHandsFreeLoopEnabled: true,
            sessionID: "session-1",
            lastTranscript: "Check Obsidian",
            statusMessage: "Sending your Agentic request...",
            lastError: nil,
            permissionRequest: nil
        )
        let hudState = AssistantHUDState(
            phase: .acting,
            title: "Spawning agent",
            detail: "Checking Obsidian"
        )

        XCTAssertTrue(
            AssistantCompactHUDManager.shouldUseLiveVoiceDisplayState(snapshot, over: hudState)
        )
    }
}
