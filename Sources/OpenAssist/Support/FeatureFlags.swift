import Foundation

enum FeatureFlags {
    private static let aiMemoryEnvironmentKey = "OPENASSIST_FEATURE_AI_MEMORY"
    private static let conversationLongTermMemoryEnvironmentKey = "OPENASSIST_FEATURE_CONVERSATION_LONG_TERM_MEMORY"
    private static let conversationAutoPromotionEnvironmentKey = "OPENASSIST_FEATURE_CONVERSATION_AUTO_PROMOTION"
    private static let strictProjectIsolationEnvironmentKey = "OPENASSIST_FEATURE_STRICT_PROJECT_ISOLATION"
    private static let conversationTupleSQLiteEnvironmentKey = "OPENASSIST_FEATURE_CONVERSATION_TUPLE_SQLITE"
    private static let crossIDEConversationSharingEnvironmentKey = "OPENASSIST_FEATURE_CROSS_IDE_CONVERSATION_SHARING"
    private static let personalAssistantEnvironmentKey = "OPENASSIST_FEATURE_PERSONAL_ASSISTANT"
    private static let crossIDEConversationSharingDefaultsKey = "OpenAssist.promptRewriteCrossIDEConversationSharingEnabled"

    enum CrossIDEConversationSharingSource: String {
        case env
        case userDefault = "user-default"
        case fallback
    }

    struct CrossIDEConversationSharingResolution {
        let enabled: Bool
        let source: CrossIDEConversationSharingSource
    }

    static var aiMemoryEnabled: Bool {
        guard let raw = ProcessInfo.processInfo.environment[aiMemoryEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else {
            return false
        }

        return ["1", "true", "yes", "on"].contains(raw)
    }

    static var conversationLongTermMemoryEnabled: Bool {
        boolFlag(
            environmentKey: conversationLongTermMemoryEnvironmentKey,
            defaultValue: true
        )
    }

    static var conversationAutoPromotionEnabled: Bool {
        boolFlag(
            environmentKey: conversationAutoPromotionEnvironmentKey,
            defaultValue: true
        )
    }

    static var strictProjectIsolationEnabled: Bool {
        boolFlag(
            environmentKey: strictProjectIsolationEnvironmentKey,
            defaultValue: true
        )
    }

    static var conversationTupleSQLiteEnabled: Bool {
        boolFlag(
            environmentKey: conversationTupleSQLiteEnvironmentKey,
            defaultValue: true
        )
    }

    static var crossIDEConversationSharingEnabled: Bool {
        crossIDEConversationSharingResolution().enabled
    }

    static var personalAssistantEnabled: Bool {
        boolFlag(
            environmentKey: personalAssistantEnvironmentKey,
            defaultValue: true
        )
    }

    static func crossIDEConversationSharingResolution(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> CrossIDEConversationSharingResolution {
        if let environmentOverride = boolValueFromEnvironment(
            crossIDEConversationSharingEnvironmentKey,
            environment: environment
        ) {
            return CrossIDEConversationSharingResolution(
                enabled: environmentOverride,
                source: .env
            )
        }

        if defaults.object(forKey: crossIDEConversationSharingDefaultsKey) != nil {
            return CrossIDEConversationSharingResolution(
                enabled: defaults.bool(forKey: crossIDEConversationSharingDefaultsKey),
                source: .userDefault
            )
        }

        return CrossIDEConversationSharingResolution(
            enabled: true,
            source: .fallback
        )
    }

    private static func boolFlag(environmentKey: String, defaultValue: Bool) -> Bool {
        guard let parsed = boolValueFromEnvironment(environmentKey) else {
            return defaultValue
        }
        return parsed
    }

    private static func boolValueFromEnvironment(
        _ environmentKey: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool? {
        guard let raw = environment[environmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !raw.isEmpty else {
            return nil
        }
        if ["1", "true", "yes", "on"].contains(raw) {
            return true
        }
        if ["0", "false", "no", "off"].contains(raw) {
            return false
        }
        return nil
    }
}
