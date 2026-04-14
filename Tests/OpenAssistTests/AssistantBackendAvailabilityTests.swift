import XCTest
@testable import OpenAssist

@MainActor
final class AssistantBackendAvailabilityTests: XCTestCase {
    func testResolvedDefaultAssistantBackendFallsBackWhenPreferredBackendIsMissing() {
        let guidanceByBackend: [AssistantRuntimeBackend: AssistantInstallGuidance] = [
            .codex: makeGuidance(for: .codex, detected: true),
            .copilot: makeGuidance(for: .copilot, detected: false),
            .claudeCode: makeGuidance(for: .claudeCode, detected: false),
            .ollamaLocal: makeGuidance(for: .ollamaLocal, detected: false)
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
            .copilot: makeGuidance(for: .copilot, detected: false),
            .claudeCode: makeGuidance(for: .claudeCode, detected: false),
            .ollamaLocal: makeGuidance(for: .ollamaLocal, detected: false)
        ]

        let backends = AssistantStore.resolvedSelectableAssistantBackends(
            preferred: .codex,
            guidanceByBackend: guidanceByBackend
        )

        XCTAssertEqual(backends, [.codex, .ollamaLocal])
    }

    func testResolvedSelectableAssistantBackendsFallsBackToCodexWhenNothingIsInstalled() {
        let guidanceByBackend: [AssistantRuntimeBackend: AssistantInstallGuidance] = [
            .codex: makeGuidance(for: .codex, detected: false),
            .copilot: makeGuidance(for: .copilot, detected: false),
            .claudeCode: makeGuidance(for: .claudeCode, detected: false),
            .ollamaLocal: makeGuidance(for: .ollamaLocal, detected: false)
        ]

        let backends = AssistantStore.resolvedSelectableAssistantBackends(
            preferred: .copilot,
            guidanceByBackend: guidanceByBackend
        )

        XCTAssertEqual(backends, [.codex, .ollamaLocal])
    }

    func testResolvedDefaultAssistantBackendKeepsClaudeWhenInstalled() {
        let guidanceByBackend: [AssistantRuntimeBackend: AssistantInstallGuidance] = [
            .codex: makeGuidance(for: .codex, detected: true),
            .copilot: makeGuidance(for: .copilot, detected: false),
            .claudeCode: makeGuidance(for: .claudeCode, detected: true),
            .ollamaLocal: makeGuidance(for: .ollamaLocal, detected: false)
        ]

        let backend = AssistantStore.resolvedDefaultAssistantBackend(
            preferred: .claudeCode,
            guidanceByBackend: guidanceByBackend
        )

        XCTAssertEqual(backend, .claudeCode)
    }

    func testResolvedDefaultAssistantBackendKeepsOllamaWhenUserPrefersLocal() {
        let guidanceByBackend: [AssistantRuntimeBackend: AssistantInstallGuidance] = [
            .codex: makeGuidance(for: .codex, detected: true),
            .copilot: makeGuidance(for: .copilot, detected: false),
            .claudeCode: makeGuidance(for: .claudeCode, detected: false),
            .ollamaLocal: makeGuidance(for: .ollamaLocal, detected: false)
        ]

        let backend = AssistantStore.resolvedDefaultAssistantBackend(
            preferred: .ollamaLocal,
            guidanceByBackend: guidanceByBackend
        )

        XCTAssertEqual(backend, .ollamaLocal)
    }

    func testResolvedSelectableAssistantBackendsShowsOnlyOllamaWhenPreferredAndNothingInstalled() {
        let guidanceByBackend: [AssistantRuntimeBackend: AssistantInstallGuidance] = [
            .codex: makeGuidance(for: .codex, detected: false),
            .copilot: makeGuidance(for: .copilot, detected: false),
            .claudeCode: makeGuidance(for: .claudeCode, detected: false),
            .ollamaLocal: makeGuidance(for: .ollamaLocal, detected: false)
        ]

        let backends = AssistantStore.resolvedSelectableAssistantBackends(
            preferred: .ollamaLocal,
            guidanceByBackend: guidanceByBackend
        )

        XCTAssertEqual(backends, [.ollamaLocal])
    }

    func testSelectableModelsForOllamaOnlyIncludeInstalledEntries() {
        let models = [
            AssistantModelOption(
                id: "gemma4:e4b",
                displayName: "Gemma 4 E4B",
                description: "",
                isDefault: true,
                hidden: false,
                supportedReasoningEfforts: [],
                defaultReasoningEffort: nil,
                isInstalled: true
            ),
            AssistantModelOption(
                id: "gemma4:26b",
                displayName: "Gemma 4 26B",
                description: "",
                isDefault: false,
                hidden: false,
                supportedReasoningEfforts: [],
                defaultReasoningEffort: nil,
                isInstalled: false
            )
        ]

        let visibleModels = AssistantStore.selectableModels(for: .ollamaLocal, from: models)

        XCTAssertEqual(visibleModels.map(\.id), ["gemma4:e4b"])
    }

    func testSelectableModelsForNonLocalBackendsKeepUninstalledEntriesVisible() {
        let models = [
            AssistantModelOption(
                id: "gpt-5",
                displayName: "GPT-5",
                description: "",
                isDefault: true,
                hidden: false,
                supportedReasoningEfforts: [],
                defaultReasoningEffort: nil,
                isInstalled: false
            )
        ]

        let visibleModels = AssistantStore.selectableModels(for: .codex, from: models)

        XCTAssertEqual(visibleModels.map(\.id), ["gpt-5"])
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
