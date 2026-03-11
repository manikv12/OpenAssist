import Foundation

enum DictationUIStatus: Equatable {
    case ready
    case listening
    case finalizing
    case openingSettings
    case copiedFromHistory
    case copiedToClipboard
    case pasteUnavailable
    case accessibilityHint
    case message(String)

    var menuText: String {
        switch self {
        case .ready:
            return "Ready"
        case .listening:
            return "Listening…"
        case .finalizing:
            return "Finalizing…"
        case .openingSettings:
            return "Opening settings…"
        case .copiedFromHistory:
            return "Copied from history"
        case .copiedToClipboard:
            return "Copied to clipboard"
        case .pasteUnavailable:
            return "Paste unavailable"
        case .accessibilityHint:
            return "Enable Accessibility for reliable hotkeys"
        case let .message(value):
            return value
        }
    }

    var resetsDictationIndicators: Bool {
        switch self {
        case .ready:
            return true
        default:
            return false
        }
    }

    static func fromTranscriberMessage(_ message: String) -> DictationUIStatus {
        switch message {
        case "Ready":
            return .ready
        case "Listening…":
            return .listening
        case "Finalizing…":
            return .finalizing
        default:
            return .message(message)
        }
    }
}
