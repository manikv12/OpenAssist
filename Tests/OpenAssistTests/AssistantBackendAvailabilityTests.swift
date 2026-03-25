import XCTest
@testable import OpenAssist

@MainActor
final class AssistantBackendAvailabilityTests: XCTestCase {
    func testResolvedDefaultAssistantBackendFallsBackWhenPreferredBackendIsMissing() {
        let guidanceByBackend: [AssistantRuntimeBackend: AssistantInstallGuidance] = [
            .codex: makeGuidance(for: .codex, detected: true),
            .copilot: makeGuidance(for: .copilot, detected: false)
        ]

        let backend = AssistantStore.resolvedDefaultAssistantBackend(
            preferred: .copilot,
            guidanceByBackend: guidanceByBackend
        )

        XCTAssertEqual(backend, .codex)
    }

    func testResolvedSelectableAssistantBackendsHidesMissingCopilot() {
        let guidanceByBackend: [AssistantRuntimeBackend: AssistantInstallGuidance] = [
            .codex: makeGuidance(for: .codex, detected: true),
            .copilot: makeGuidance(for: .copilot, detected: false)
        ]

        let backends = AssistantStore.resolvedSelectableAssistantBackends(
            preferred: .codex,
            guidanceByBackend: guidanceByBackend
        )

        XCTAssertEqual(backends, [.codex])
    }

    func testResolvedSelectableAssistantBackendsFallsBackToCodexWhenNothingIsInstalled() {
        let guidanceByBackend: [AssistantRuntimeBackend: AssistantInstallGuidance] = [
            .codex: makeGuidance(for: .codex, detected: false),
            .copilot: makeGuidance(for: .copilot, detected: false)
        ]

        let backends = AssistantStore.resolvedSelectableAssistantBackends(
            preferred: .copilot,
            guidanceByBackend: guidanceByBackend
        )

        XCTAssertEqual(backends, [.codex])
    }

    private func makeGuidance(
        for backend: AssistantRuntimeBackend,
        detected: Bool
    ) -> AssistantInstallGuidance {
        var guidance = AssistantInstallGuidance.placeholder(for: backend)
        guidance.codexDetected = detected
        return guidance
    }
}
