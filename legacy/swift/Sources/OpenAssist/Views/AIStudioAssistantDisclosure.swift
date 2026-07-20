import Foundation

enum AIStudioAssistantSetupStage: Equatable {
    case installCodex
    case signIn
    case enableAssistant
    case configureAssistant
    case needsAttention
}

enum AIStudioAssistantDisclosure {
    static func setupStage(
        environmentState: AssistantEnvironmentState,
        assistantEnabled: Bool
    ) -> AIStudioAssistantSetupStage {
        switch environmentState {
        case .missingCodex:
            return .installCodex
        case .needsLogin:
            return .signIn
        case .ready:
            return assistantEnabled ? .configureAssistant : .enableAssistant
        case .failed:
            return .needsAttention
        }
    }

    static func showsAdvancedPages(
        environmentState: AssistantEnvironmentState,
        assistantEnabled: Bool
    ) -> Bool {
        setupStage(
            environmentState: environmentState,
            assistantEnabled: assistantEnabled
        ) == .configureAssistant
    }
}
