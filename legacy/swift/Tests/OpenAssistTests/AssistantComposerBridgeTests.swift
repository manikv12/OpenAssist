import XCTest
@testable import OpenAssist

@MainActor
final class AssistantComposerBridgeTests: XCTestCase {
    func testLegacyAssistantOrbTargetMapsToAssistantCompact() {
        XCTAssertEqual(
            AssistantComposerBridge.CaptureTarget.assistantOrb,
            .assistantCompact
        )
    }
}
