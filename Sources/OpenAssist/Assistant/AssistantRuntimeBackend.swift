import Foundation

enum AssistantRuntimeBackend: String, CaseIterable, Identifiable, Codable, Sendable {
    case codex
    case copilot

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex:
            return "Codex"
        case .copilot:
            return "GitHub Copilot"
        }
    }

    var shortDisplayName: String {
        switch self {
        case .codex:
            return "Codex"
        case .copilot:
            return "Copilot"
        }
    }

    var executableName: String {
        switch self {
        case .codex:
            return "codex"
        case .copilot:
            return "copilot"
        }
    }

    var installCommands: [String] {
        switch self {
        case .codex:
            return ["npm install -g @openai/codex"]
        case .copilot:
            return ["npm install -g @github/copilot"]
        }
    }

    var loginCommands: [String] {
        switch self {
        case .codex:
            return ["codex login"]
        case .copilot:
            return ["copilot login"]
        }
    }

    var docsURL: URL? {
        switch self {
        case .codex:
            return URL(string: "https://developers.openai.com/codex/app-server")
        case .copilot:
            return URL(string: "https://docs.github.com/copilot/concepts/agents/about-copilot-cli")
        }
    }

    var sessionSource: AssistantSessionSource {
        switch self {
        case .codex:
            return .appServer
        case .copilot:
            return .cli
        }
    }

    var installActionTitle: String {
        switch self {
        case .codex:
            return "Install Codex"
        case .copilot:
            return "Install Copilot CLI"
        }
    }

    var docsActionTitle: String {
        switch self {
        case .codex:
            return "Codex Docs"
        case .copilot:
            return "Copilot Docs"
        }
    }

    var loginActionTitle: String {
        switch self {
        case .codex:
            return "Sign In with ChatGPT"
        case .copilot:
            return "Sign In to GitHub Copilot"
        }
    }

    var alreadySignedInMessage: String {
        "\(displayName) is already signed in."
    }

    var connectedSummary: String {
        "\(displayName) is connected"
    }

    var activeSummary: String {
        "\(displayName) is working"
    }

    var loginRequiredSummary: String {
        switch self {
        case .codex:
            return "Sign in to Codex"
        case .copilot:
            return "Sign in to GitHub Copilot"
        }
    }

    var signInPromptSummary: String {
        switch self {
        case .codex:
            return "Sign in with ChatGPT to use Codex"
        case .copilot:
            return "Sign in to GitHub Copilot to use the assistant"
        }
    }

    var missingInstallSummary: String {
        "\(installActionTitle) to start the assistant"
    }

    var startupSummary: String {
        switch self {
        case .codex:
            return "Connecting to Codex App Server"
        case .copilot:
            return "Connecting to GitHub Copilot"
        }
    }

    var startupFailureSummary: String {
        switch self {
        case .codex:
            return "Could not start Codex App Server"
        case .copilot:
            return "Could not start GitHub Copilot"
        }
    }

    var idleSummary: String {
        "Assistant is idle"
    }

    var unavailableConversationMessage: String {
        "\(displayName) is not available right now."
    }

    var waitingToStartConversationMessage: String {
        "Waiting for \(displayName) to start."
    }

    var connectingConversationMessage: String {
        "Connecting to \(displayName)."
    }

    var needsAttentionSummary: String {
        "\(displayName) needs attention"
    }

    var loadingModelsMessage: String {
        "Loading models from \(displayName) before chat starts."
    }

    var signedOutSummary: String {
        switch self {
        case .codex:
            return "Signed out of Codex"
        case .copilot:
            return "Signed out of GitHub Copilot"
        }
    }

    var startedSessionMessage: String {
        switch self {
        case .codex:
            return "Started a new Codex thread."
        case .copilot:
            return "Started a new GitHub Copilot session."
        }
    }

    func loadedSessionMessage(_ sessionID: String) -> String {
        switch self {
        case .codex:
            return "Loaded Codex thread \(sessionID)."
        case .copilot:
            return "Loaded GitHub Copilot session \(sessionID)."
        }
    }
}

enum AssistantRuntimeLoginAction: Equatable, Sendable {
    case none
    case openURL(URL)
    case runCommand(String)
}
