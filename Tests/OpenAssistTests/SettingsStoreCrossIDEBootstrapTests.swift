import XCTest
@testable import OpenAssist

@MainActor
final class SettingsStoreCrossIDEBootstrapTests: XCTestCase {
    private func makeIsolatedDefaults() -> UserDefaults {
        let suite = "OpenAssistTests.SettingsStore.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Failed to create isolated defaults suite: \(suite)")
        }
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testBootstrapAppliesOneTimeMigrationForFreshDefaults() {
        let defaults = makeIsolatedDefaults()

        let result = SettingsStore.resolveCrossIDEConversationSharingBootstrap(
            defaults: defaults,
            featureResolution: .init(enabled: true, source: .fallback)
        )

        XCTAssertTrue(result.settingEnabled)
        XCTAssertTrue(result.runtimeEnabled)
        XCTAssertEqual(result.source, "migration")
        XCTAssertTrue(result.migrationApplied)
        XCTAssertEqual(
            defaults.bool(forKey: "OpenAssist.promptRewriteCrossIDEConversationSharingEnabled"),
            true
        )
        XCTAssertEqual(
            defaults.bool(forKey: SettingsStore.crossIDEConversationSharingMigrationDefaultsKey),
            true
        )
    }

    func testBootstrapMigratesExistingFalseValueWhenSentinelMissing() {
        let defaults = makeIsolatedDefaults()
        defaults.set(false, forKey: "OpenAssist.promptRewriteCrossIDEConversationSharingEnabled")

        let result = SettingsStore.resolveCrossIDEConversationSharingBootstrap(
            defaults: defaults,
            featureResolution: .init(enabled: true, source: .userDefault)
        )

        XCTAssertTrue(result.settingEnabled)
        XCTAssertTrue(result.runtimeEnabled)
        XCTAssertEqual(result.source, "migration")
        XCTAssertTrue(result.migrationApplied)
        XCTAssertEqual(
            defaults.bool(forKey: "OpenAssist.promptRewriteCrossIDEConversationSharingEnabled"),
            true
        )
        XCTAssertEqual(
            defaults.bool(forKey: SettingsStore.crossIDEConversationSharingMigrationDefaultsKey),
            true
        )
    }

    func testBootstrapSkipsMigrationWhenEnvironmentHardOffAndSettingMissing() {
        let defaults = makeIsolatedDefaults()

        let result = SettingsStore.resolveCrossIDEConversationSharingBootstrap(
            defaults: defaults,
            featureResolution: .init(enabled: false, source: .env)
        )

        XCTAssertFalse(result.settingEnabled)
        XCTAssertFalse(result.runtimeEnabled)
        XCTAssertEqual(result.source, "env")
        XCTAssertFalse(result.migrationApplied)
        XCTAssertNil(defaults.object(forKey: "OpenAssist.promptRewriteCrossIDEConversationSharingEnabled"))
        XCTAssertNil(defaults.object(forKey: SettingsStore.crossIDEConversationSharingMigrationDefaultsKey))
    }

    func testBootstrapDoesNotForceRewriteWhenMigrationAlreadyApplied() {
        let defaults = makeIsolatedDefaults()
        defaults.set(true, forKey: SettingsStore.crossIDEConversationSharingMigrationDefaultsKey)
        defaults.set(false, forKey: "OpenAssist.promptRewriteCrossIDEConversationSharingEnabled")

        let result = SettingsStore.resolveCrossIDEConversationSharingBootstrap(
            defaults: defaults,
            featureResolution: .init(enabled: false, source: .userDefault)
        )

        XCTAssertFalse(result.settingEnabled)
        XCTAssertFalse(result.runtimeEnabled)
        XCTAssertEqual(result.source, "user-default")
        XCTAssertFalse(result.migrationApplied)
    }

    func testRestoredIntegerReturnsDefaultWhenValueIsMissing() {
        let defaults = makeIsolatedDefaults()

        XCTAssertEqual(
            SettingsStore.restoredInteger(
                defaults: defaults,
                key: "OpenAssist.testMissingInt",
                defaultValue: 75
            ),
            75
        )
    }

    func testRestoredIntegerPreservesZeroForUnlimitedSettings() {
        let defaults = makeIsolatedDefaults()
        defaults.set(0, forKey: "OpenAssist.testUnlimitedInt")

        XCTAssertEqual(
            SettingsStore.restoredInteger(
                defaults: defaults,
                key: "OpenAssist.testUnlimitedInt",
                defaultValue: 75
            ),
            0
        )
    }

    func testAssistantCompactPresentationStyleDefaultsToOrbWhenMissing() {
        let defaults = makeIsolatedDefaults()

        XCTAssertEqual(
            SettingsStore.restoredAssistantCompactPresentationStyle(defaults: defaults),
            .orb
        )
    }

    func testAssistantCompactPresentationStyleRestoresStoredNotchValue() {
        let defaults = makeIsolatedDefaults()
        defaults.set("notch", forKey: "OpenAssist.assistantCompactPresentationStyle")

        XCTAssertEqual(
            SettingsStore.restoredAssistantCompactPresentationStyle(defaults: defaults),
            .notch
        )
    }

    func testAssistantCompactPresentationStyleRestoresStoredSidebarValue() {
        let defaults = makeIsolatedDefaults()
        defaults.set("sidebar", forKey: "OpenAssist.assistantCompactPresentationStyle")

        XCTAssertEqual(
            SettingsStore.restoredAssistantCompactPresentationStyle(defaults: defaults),
            .sidebar
        )
    }

    func testAssistantCompactPresentationStyleFallsBackToOrbForInvalidValue() {
        let defaults = makeIsolatedDefaults()
        defaults.set("floating-pill", forKey: "OpenAssist.assistantCompactPresentationStyle")

        XCTAssertEqual(
            SettingsStore.restoredAssistantCompactPresentationStyle(defaults: defaults),
            .orb
        )
    }

    func testAssistantCompactSidebarEdgeDefaultsToLeftWhenMissing() {
        let defaults = makeIsolatedDefaults()

        XCTAssertEqual(
            SettingsStore.restoredAssistantCompactSidebarEdge(defaults: defaults),
            .left
        )
    }

    func testAssistantCompactSidebarEdgeRestoresStoredRightValue() {
        let defaults = makeIsolatedDefaults()
        defaults.set("right", forKey: "OpenAssist.assistantCompactSidebarEdge")

        XCTAssertEqual(
            SettingsStore.restoredAssistantCompactSidebarEdge(defaults: defaults),
            .right
        )
    }

    func testAssistantCompactSidebarPinnedDefaultsToFalseWhenMissing() {
        let defaults = makeIsolatedDefaults()

        XCTAssertFalse(
            SettingsStore.restoredAssistantCompactSidebarPinned(defaults: defaults)
        )
    }

    func testAssistantCompactSidebarPinnedRestoresStoredTrueValue() {
        let defaults = makeIsolatedDefaults()
        defaults.set(true, forKey: "OpenAssist.assistantCompactSidebarPinned")

        XCTAssertTrue(
            SettingsStore.restoredAssistantCompactSidebarPinned(defaults: defaults)
        )
    }

    func testGooglePromptRewriteAndGeminiTranscriptionShareSameKeychainAccount() {
        XCTAssertEqual(
            SettingsStore.keychainAccount(for: .google),
            SettingsStore.googleAIStudioAPIKeychainAccount
        )
        XCTAssertEqual(
            SettingsStore.cloudTranscriptionKeychainAccount(for: .gemini),
            SettingsStore.googleAIStudioAPIKeychainAccount
        )
    }

    func testGoogleAIStudioUsesStableDefaultImageModel() {
        XCTAssertEqual(
            SettingsStore.googleAIStudioImageGenerationDefaultModel,
            "gemini-2.5-flash-image"
        )
    }
}
