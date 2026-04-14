import XCTest
@testable import OpenAssist

@MainActor
final class SettingsStoreAssistantModelPreferenceTests: XCTestCase {
    private func makeIsolatedDefaults() -> UserDefaults {
        let suite = "OpenAssistTests.SettingsStore.AssistantPreferences.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Failed to create isolated defaults suite: \(suite)")
        }
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testMigratesLegacyAssistantModelValuesIntoSelectedBackendScope() {
        let defaults = makeIsolatedDefaults()
        defaults.set(AssistantRuntimeBackend.copilot.rawValue, forKey: "OpenAssist.assistantBackend")
        defaults.set("legacy-assistant-model", forKey: "OpenAssist.assistantPreferredModelID")
        defaults.set("legacy-subagent-model", forKey: "OpenAssist.assistantPreferredSubagentModelID")

        let store = SettingsStore(defaults: defaults)

        XCTAssertEqual(store.assistantBackend, .copilot)
        XCTAssertEqual(store.assistantPreferredModelID, "legacy-assistant-model")
        XCTAssertEqual(store.assistantPreferredSubagentModelID, "legacy-subagent-model")

        let scopedModels = scopedDictionary(for: "OpenAssist.assistantPreferredModelIDByBackend", in: defaults)
        let scopedSubagentModels = scopedDictionary(
            for: "OpenAssist.assistantPreferredSubagentModelIDByBackend",
            in: defaults
        )

        XCTAssertEqual(scopedModels[AssistantRuntimeBackend.copilot.rawValue], "legacy-assistant-model")
        XCTAssertEqual(scopedSubagentModels[AssistantRuntimeBackend.copilot.rawValue], "legacy-subagent-model")
    }

    func testAssistantModelPreferencesPersistPerBackend() {
        let defaults = makeIsolatedDefaults()
        let store = SettingsStore(defaults: defaults)

        store.assistantBackend = .codex
        store.assistantPreferredModelID = "codex-model"
        store.assistantPreferredSubagentModelID = "codex-subagent-model"

        store.assistantBackend = .copilot
        store.assistantPreferredModelID = "copilot-model"
        store.assistantPreferredSubagentModelID = "copilot-subagent-model"

        let scopedModels = scopedDictionary(for: "OpenAssist.assistantPreferredModelIDByBackend", in: defaults)
        let scopedSubagentModels = scopedDictionary(
            for: "OpenAssist.assistantPreferredSubagentModelIDByBackend",
            in: defaults
        )

        XCTAssertEqual(scopedModels[AssistantRuntimeBackend.codex.rawValue], "codex-model")
        XCTAssertEqual(scopedModels[AssistantRuntimeBackend.copilot.rawValue], "copilot-model")
        XCTAssertEqual(scopedSubagentModels[AssistantRuntimeBackend.codex.rawValue], "codex-subagent-model")
        XCTAssertEqual(scopedSubagentModels[AssistantRuntimeBackend.copilot.rawValue], "copilot-subagent-model")

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.assistantBackend, .copilot)
        XCTAssertEqual(reloaded.assistantPreferredModelID, "copilot-model")
        XCTAssertEqual(reloaded.assistantPreferredSubagentModelID, "copilot-subagent-model")

        reloaded.assistantBackend = .codex
        XCTAssertEqual(reloaded.assistantPreferredModelID, "codex-model")
        XCTAssertEqual(reloaded.assistantPreferredSubagentModelID, "codex-subagent-model")
    }

    func testExistingScopedPreferenceWinsOverLegacyValueDuringMigration() {
        let defaults = makeIsolatedDefaults()
        defaults.set(AssistantRuntimeBackend.codex.rawValue, forKey: "OpenAssist.assistantBackend")
        defaults.set(
            [
                AssistantRuntimeBackend.codex.rawValue: "scoped-model"
            ],
            forKey: "OpenAssist.assistantPreferredModelIDByBackend"
        )
        defaults.set("legacy-model", forKey: "OpenAssist.assistantPreferredModelID")

        let store = SettingsStore(defaults: defaults)

        XCTAssertEqual(store.assistantPreferredModelID, "scoped-model")
        XCTAssertEqual(
            scopedDictionary(for: "OpenAssist.assistantPreferredModelIDByBackend", in: defaults)[AssistantRuntimeBackend.codex.rawValue],
            "scoped-model"
        )
    }

    private func scopedDictionary(for key: String, in defaults: UserDefaults) -> [String: String] {
        guard let rawDictionary = defaults.dictionary(forKey: key) else {
            return [:]
        }
        var normalized: [String: String] = [:]
        for (rawKey, rawValue) in rawDictionary {
            guard let value = rawValue as? String else { continue }
            normalized[rawKey] = value
        }
        return normalized
    }
}
