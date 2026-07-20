import Foundation

enum OpenAssistResponseStylePreset: String, CaseIterable, Identifiable {
    case fast
    case balanced
    case reliable

    var id: Self { self }

    var displayName: String {
        switch self {
        case .fast:
            return "Fast"
        case .balanced:
            return "Balanced"
        case .reliable:
            return "Reliable"
        }
    }

    var detail: String {
        switch self {
        case .fast:
            return "Respond sooner, even if a slower model may sometimes stop early."
        case .balanced:
            return "A good default for most people."
        case .reliable:
            return "Wait longer for slower models and weaker connections."
        }
    }

    var promptRewriteTimeoutSeconds: Double {
        switch self {
        case .fast:
            return 6
        case .balanced:
            return 12
        case .reliable:
            return 30
        }
    }

    var cloudTranscriptionTimeoutSeconds: Double {
        switch self {
        case .fast:
            return 15
        case .balanced:
            return 30
        case .reliable:
            return 60
        }
    }

    static func forPromptRewriteTimeout(_ seconds: Double) -> Self {
        switch seconds {
        case ..<9:
            return .fast
        case ..<22:
            return .balanced
        default:
            return .reliable
        }
    }

    static func forCloudTranscriptionTimeout(_ seconds: Double) -> Self {
        switch seconds {
        case ..<22:
            return .fast
        case ..<45:
            return .balanced
        default:
            return .reliable
        }
    }
}
