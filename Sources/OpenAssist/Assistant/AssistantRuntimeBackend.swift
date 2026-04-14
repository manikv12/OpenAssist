import Foundation

enum AssistantRuntimeBackend: String, CaseIterable, Identifiable, Codable, Sendable {
    case codex
    case copilot
    case claudeCode
    case ollamaLocal

    var id: String { rawValue }

    var brandHue: (red: Double, green: Double, blue: Double) {
        switch self {
        case .codex:
            return (0.498, 0.580, 1.0)     // #7f94ff
        case .copilot:
            return (0.784, 0.596, 0.992)   // #c898fd
        case .claudeCode:
            return (1.0, 0.702, 0.420)     // #ffb36b
        case .ollamaLocal:
            return (0.380, 0.749, 0.451)   // #61bf73
        }
    }

    var displayName: String {
        switch self {
        case .codex:
            return "Codex"
        case .copilot:
            return "GitHub Copilot"
        case .claudeCode:
            return "Claude Code"
        case .ollamaLocal:
            return "Ollama (Local)"
        }
    }

    var shortDisplayName: String {
        switch self {
        case .codex:
            return "Codex"
        case .copilot:
            return "Copilot"
        case .claudeCode:
            return "Claude"
        case .ollamaLocal:
            return "Ollama"
        }
    }

    var executableName: String {
        switch self {
        case .codex:
            return "codex"
        case .copilot:
            return "copilot"
        case .claudeCode:
            return "claude"
        case .ollamaLocal:
            return "ollama"
        }
    }

    var installCommands: [String] {
        switch self {
        case .codex:
            return ["npm install -g @openai/codex"]
        case .copilot:
            return ["npm install -g @github/copilot"]
        case .claudeCode:
            return ["npm install -g @anthropic-ai/claude-code"]
        case .ollamaLocal:
            return []
        }
    }

    var loginCommands: [String] {
        switch self {
        case .codex:
            return ["codex login"]
        case .copilot:
            return ["copilot login"]
        case .claudeCode:
            return ["claude auth login"]
        case .ollamaLocal:
            return []
        }
    }

    var docsURL: URL? {
        switch self {
        case .codex:
            return URL(string: "https://developers.openai.com/codex/app-server")
        case .copilot:
            return URL(string: "https://docs.github.com/copilot/concepts/agents/about-copilot-cli")
        case .claudeCode:
            return URL(string: "https://code.claude.com/docs/en/headless")
        case .ollamaLocal:
            return URL(string: "https://ollama.com/library/gemma4")
        }
    }

    var sessionSource: AssistantSessionSource {
        switch self {
        case .codex:
            return .appServer
        case .copilot:
            return .cli
        case .claudeCode:
            return .cli
        case .ollamaLocal:
            return .openAssist
        }
    }

    var installActionTitle: String {
        switch self {
        case .codex:
            return "Install Codex"
        case .copilot:
            return "Install Copilot CLI"
        case .claudeCode:
            return "Install Claude Code"
        case .ollamaLocal:
            return "Open Local AI Setup"
        }
    }

    var docsActionTitle: String {
        switch self {
        case .codex:
            return "Codex Docs"
        case .copilot:
            return "Copilot Docs"
        case .claudeCode:
            return "Claude Docs"
        case .ollamaLocal:
            return "Gemma 4 Guide"
        }
    }

    var loginActionTitle: String {
        switch self {
        case .codex:
            return "Sign In with ChatGPT"
        case .copilot:
            return "Sign In to GitHub Copilot"
        case .claudeCode:
            return "Sign In to Claude Code"
        case .ollamaLocal:
            return "Open Local AI Setup"
        }
    }

    var requiresLogin: Bool {
        switch self {
        case .codex, .copilot, .claudeCode:
            return true
        case .ollamaLocal:
            return false
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
        case .claudeCode:
            return "Sign in to Claude Code"
        case .ollamaLocal:
            return "Open Local AI Setup"
        }
    }

    var signInPromptSummary: String {
        switch self {
        case .codex:
            return "Sign in with ChatGPT to use Codex"
        case .copilot:
            return "Sign in to GitHub Copilot to use the assistant"
        case .claudeCode:
            return "Sign in to Claude Code to use the assistant"
        case .ollamaLocal:
            return "Open Local AI Setup to use Ollama and Gemma 4"
        }
    }

    var missingInstallSummary: String {
        switch self {
        case .ollamaLocal:
            return "Open Local AI Setup to install Ollama or download Gemma 4"
        case .codex, .copilot, .claudeCode:
            return "\(installActionTitle) to start the assistant"
        }
    }

    var startupSummary: String {
        switch self {
        case .codex:
            return "Connecting to Codex App Server"
        case .copilot:
            return "Connecting to GitHub Copilot"
        case .claudeCode:
            return "Preparing Claude Code"
        case .ollamaLocal:
            return "Preparing Ollama (Local)"
        }
    }

    var startupFailureSummary: String {
        switch self {
        case .codex:
            return "Could not start Codex App Server"
        case .copilot:
            return "Could not start GitHub Copilot"
        case .claudeCode:
            return "Could not start Claude Code"
        case .ollamaLocal:
            return "Could not start Ollama (Local)"
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
        case .claudeCode:
            return "Signed out of Claude Code"
        case .ollamaLocal:
            return "Ollama (Local) does not use sign-in"
        }
    }

    var startedSessionMessage: String {
        switch self {
        case .codex:
            return "Started a new Codex thread."
        case .copilot:
            return "Started a new GitHub Copilot session."
        case .claudeCode:
            return "Started a new Claude Code session."
        case .ollamaLocal:
            return "Started a new local Ollama thread."
        }
    }

    func loadedSessionMessage(_ sessionID: String) -> String {
        switch self {
        case .codex:
            return "Loaded Codex thread \(sessionID)."
        case .copilot:
            return "Loaded GitHub Copilot session \(sessionID)."
        case .claudeCode:
            return "Loaded Claude Code session \(sessionID)."
        case .ollamaLocal:
            return "Loaded local Ollama thread \(sessionID)."
        }
    }
}

enum AssistantRuntimeLoginAction: Equatable, Sendable {
    case none
    case openURL(URL)
    case runCommand(String)
}
