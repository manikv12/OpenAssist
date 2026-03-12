import XCTest
@testable import OpenAssist

final class AIStudioAssistantDisclosureTests: XCTestCase {
    func testMissingCodexRequiresInstallBeforeAssistantOptionsAppear() {
        XCTAssertEqual(
            AIStudioAssistantDisclosure.setupStage(
                environmentState: .missingCodex,
                assistantEnabled: false
            ),
            .installCodex
        )

        XCTAssertFalse(
            AIStudioAssistantDisclosure.showsAdvancedPages(
                environmentState: .missingCodex,
                assistantEnabled: true
            )
        )
    }

    func testNeedsLoginRequiresSignInBeforeAssistantOptionsAppear() {
        XCTAssertEqual(
            AIStudioAssistantDisclosure.setupStage(
                environmentState: .needsLogin,
                assistantEnabled: false
            ),
            .signIn
        )

        XCTAssertFalse(
            AIStudioAssistantDisclosure.showsAdvancedPages(
                environmentState: .needsLogin,
                assistantEnabled: true
            )
        )
    }

    func testReadyAssistantShowsActivationStepBeforeAdvancedPages() {
        XCTAssertEqual(
            AIStudioAssistantDisclosure.setupStage(
                environmentState: .ready,
                assistantEnabled: false
            ),
            .enableAssistant
        )

        XCTAssertFalse(
            AIStudioAssistantDisclosure.showsAdvancedPages(
                environmentState: .ready,
                assistantEnabled: false
            )
        )
    }

    func testReadyAndEnabledAssistantShowsAdvancedPages() {
        XCTAssertEqual(
            AIStudioAssistantDisclosure.setupStage(
                environmentState: .ready,
                assistantEnabled: true
            ),
            .configureAssistant
        )

        XCTAssertTrue(
            AIStudioAssistantDisclosure.showsAdvancedPages(
                environmentState: .ready,
                assistantEnabled: true
            )
        )
    }

    func testFailedAssistantStateNeedsAttention() {
        XCTAssertEqual(
            AIStudioAssistantDisclosure.setupStage(
                environmentState: .failed,
                assistantEnabled: true
            ),
            .needsAttention
        )

        XCTAssertFalse(
            AIStudioAssistantDisclosure.showsAdvancedPages(
                environmentState: .failed,
                assistantEnabled: true
            )
        )
    }
}
