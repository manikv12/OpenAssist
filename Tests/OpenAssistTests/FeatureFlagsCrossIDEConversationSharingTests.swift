import XCTest
@testable import OpenAssist

final class FeatureFlagsCrossIDEConversationSharingTests: XCTestCase {
    private func makeIsolatedDefaults() -> UserDefaults {
        let suite = "OpenAssistTests.FeatureFlags.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Failed to create isolated defaults suite: \(suite)")
        }
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testCrossIDEConversationSharingResolutionPrefersEnvironmentTrue() {
        let defaults = makeIsolatedDefaults()
        defaults.set(false, forKey: "OpenAssist.promptRewriteCrossIDEConversationSharingEnabled")

        let resolution = FeatureFlags.crossIDEConversationSharingResolution(
            environment: ["OPENASSIST_FEATURE_CROSS_IDE_CONVERSATION_SHARING": "true"],
            defaults: defaults
        )

        XCTAssertTrue(resolution.enabled)
        XCTAssertEqual(resolution.source, .env)
    }

    func testCrossIDEConversationSharingResolutionPrefersEnvironmentFalse() {
        let defaults = makeIsolatedDefaults()
        defaults.set(true, forKey: "OpenAssist.promptRewriteCrossIDEConversationSharingEnabled")

        let resolution = FeatureFlags.crossIDEConversationSharingResolution(
            environment: ["OPENASSIST_FEATURE_CROSS_IDE_CONVERSATION_SHARING": "0"],
            defaults: defaults
        )

        XCTAssertFalse(resolution.enabled)
        XCTAssertEqual(resolution.source, .env)
    }

    func testCrossIDEConversationSharingResolutionUsesUserDefaultWhenSet() {
        let defaults = makeIsolatedDefaults()
        defaults.set(false, forKey: "OpenAssist.promptRewriteCrossIDEConversationSharingEnabled")

        let resolution = FeatureFlags.crossIDEConversationSharingResolution(
            environment: [:],
            defaults: defaults
        )

        XCTAssertFalse(resolution.enabled)
        XCTAssertEqual(resolution.source, .userDefault)
    }

    func testCrossIDEConversationSharingResolutionFallsBackToEnabled() {
        let defaults = makeIsolatedDefaults()

        let resolution = FeatureFlags.crossIDEConversationSharingResolution(
            environment: [:],
            defaults: defaults
        )

        XCTAssertTrue(resolution.enabled)
        XCTAssertEqual(resolution.source, .fallback)
    }
}
