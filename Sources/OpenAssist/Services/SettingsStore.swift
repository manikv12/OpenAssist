import AppKit
import Foundation
import Security
import SwiftUI

enum RecognitionMode: String, CaseIterable, Identifiable {
    case localOnly = "Local Only"
    case cloudOnly = "Cloud Only"
    case automatic = "Automatic"

    var id: Self { self }

    var displayName: String {
        rawValue
    }

    var helpText: String {
        switch self {
        case .localOnly:
            return "All processing stays on your Mac. Faster and fully private, but may be less accurate for complex speech."
        case .cloudOnly:
            return "Audio is sent to Apple servers for recognition. More accurate for difficult speech, but requires an internet connection."
        case .automatic:
            return "Apple decides whether to use on-device or server recognition based on conditions."
        }
    }
}

enum TranscriptionEngineType: String, CaseIterable, Identifiable {
    case appleSpeech = "Apple Speech"
    case whisperCpp = "whisper.cpp"
    case cloudProviders = "Cloud Providers"

    var id: Self { self }

    var displayName: String {
        rawValue
    }

    var helpText: String {
        switch self {
        case .appleSpeech:
            return "Uses Apple Speech recognition. Supports on-device and cloud recognition modes."
        case .whisperCpp:
            return "Uses local whisper.cpp models downloaded to this Mac. No cloud transcription is used."
        case .cloudProviders:
            return "Uses remote transcription providers with either your API key or the ChatGPT / Codex session already signed in on this Mac."
        }
    }
}

enum CloudTranscriptionProvider: String, CaseIterable, Identifiable {
    case openAI = "OpenAI"
    case groq = "Groq"
    case deepgram = "Deepgram"
    case gemini = "Google Gemini (AI Studio)"
    case codexSession = "ChatGPT / Codex Session"

    var id: Self { self }

    var displayName: String {
        rawValue
    }

    var defaultModel: String {
        switch self {
        case .openAI:
            return "gpt-4o-mini-transcribe"
        case .groq:
            return "whisper-large-v3-turbo"
        case .deepgram:
            return "nova-3"
        case .gemini:
            return "gemini-2.5-flash"
        case .codexSession:
            return "gpt-4o-mini-transcribe"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openAI:
            return "https://api.openai.com/v1"
        case .groq:
            return "https://api.groq.com/openai/v1"
        case .deepgram:
            return "https://api.deepgram.com/v1/listen"
        case .gemini:
            return "https://generativelanguage.googleapis.com/v1beta"
        case .codexSession:
            return "https://chatgpt.com/backend-api"
        }
    }

    var requiresAPIKey: Bool {
        switch self {
        case .codexSession:
            return false
        case .openAI, .groq, .deepgram, .gemini:
            return true
        }
    }

    var helpText: String {
        switch self {
        case .openAI:
            return "OpenAI transcription models via /audio/transcriptions."
        case .groq:
            return "Groq-hosted Whisper transcription models via OpenAI-compatible endpoint."
        case .deepgram:
            return "Deepgram speech-to-text API with low-latency cloud transcription."
        case .gemini:
            return "Google Gemini generateContent audio transcription using AI Studio API key."
        case .codexSession:
            return "Uses the ChatGPT or Codex sign-in already active on this Mac instead of a separate transcription API key."
        }
    }
}

enum PromptRewriteProviderMode: String, CaseIterable, Identifiable {
    case openAI = "OpenAI"
    case google = "Google AI Studio (Gemini)"
    case openRouter = "OpenRouter"
    case groq = "Groq"
    case anthropic = "Anthropic"
    case ollama = "Ollama (Local)"

    var id: Self { self }

    var displayName: String {
        rawValue
    }

    var defaultModel: String {
        switch self {
        case .openAI:
            return "gpt-4.1-mini"
        case .google:
            return "gemini-3-flash-preview"
        case .openRouter:
            return "openai/gpt-4.1-mini"
        case .groq:
            return "llama-3.3-70b-versatile"
        case .anthropic:
            return "claude-3-5-sonnet-latest"
        case .ollama:
            return "llama3.1"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openAI:
            return "https://api.openai.com/v1"
        case .google:
            return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .openRouter:
            return "https://openrouter.ai/api/v1"
        case .groq:
            return "https://api.groq.com/openai/v1"
        case .anthropic:
            return "https://api.anthropic.com/v1"
        case .ollama:
            return "http://localhost:11434/v1"
        }
    }

    var requiresAPIKey: Bool {
        switch self {
        case .ollama:
            return false
        case .openAI, .google, .openRouter, .groq, .anthropic:
            return true
        }
    }

    var helpText: String {
        switch self {
        case .openAI:
            return "Uses OpenAI to analyze memory context and suggest improved prompts. Supports OAuth sign-in."
        case .google:
            return "Uses Google Gemini models through the Google AI Studio OpenAI-compatible API."
        case .openRouter:
            return "Uses OpenRouter-compatible models for memory-aware prompt rewrites."
        case .groq:
            return "Uses Groq-hosted models through OpenAI-compatible API."
        case .anthropic:
            return "Uses Anthropic Messages API for memory-aware prompt rewrites. Supports OAuth sign-in."
        case .ollama:
            return "Uses local Ollama server via OpenAI-compatible endpoint."
        }
    }
}

enum PromptRewriteStylePreset: String, CaseIterable, Identifiable {
    case balanced = "Balanced (Default)"
    case formal = "Formal"
    case casual = "Casual"
    case architect = "Architect"
    case seniorDeveloper = "Senior Developer"
    case juniorDeveloper = "Junior Developer"
    case technicalWriter = "Technical Writer"
    case polishedWriter = "Polished Writer"

    var id: Self { self }

    var styleInstruction: String {
        switch self {
        case .balanced:
            return "Write with a clear, practical, and structured tone."
        case .formal:
            return "Write in a formal, professional tone with precise wording."
        case .casual:
            return "Write in a friendly, conversational tone while staying clear."
        case .architect:
            return "Write like a software architect: emphasize system design constraints, trade-offs, and implementation boundaries."
        case .seniorDeveloper:
            return "Write like a senior developer: direct, technical, and execution-focused with practical details."
        case .juniorDeveloper:
            return "Write as a supportive junior developer collaborator: straightforward, curious, and explicit about assumptions."
        case .technicalWriter:
            return "Write like a technical writer: concise, unambiguous, and easy to scan with strong structure."
        case .polishedWriter:
            return "Write like a polished writer: smooth phrasing, coherent flow, and crisp language."
        }
    }
}

enum WaveformTheme: String, CaseIterable, Identifiable {
    case vibrantSpectrum = "Vibrant Spectrum"
    case professionalTech = "Professional Tech"
    case monochrome = "Monochrome"
    case neonLagoon = "Neon Lagoon"
    case sunsetCandy = "Sunset Candy"
    case cosmicPop = "Cosmic Pop"
    case mintBlush = "Mint Blush"

    var id: Self { self }
}

enum AppChromeStyle: String, CaseIterable, Identifiable {
    case glassHighContrast = "Glass (High Contrast)"
    case classic = "Classic"

    var id: Self { self }
}

enum AssistantCompactPresentationStyle: String, CaseIterable, Identifiable, Codable {
    case orb = "orb"
    case notch = "notch"
    case sidebar = "sidebar"

    var id: Self { self }

    var displayName: String {
        switch self {
        case .orb:
            return "Orb"
        case .notch:
            return "Notch"
        case .sidebar:
            return "Sidebar"
        }
    }
}

enum AssistantCompactSidebarEdge: String, CaseIterable, Identifiable, Codable {
    case left = "left"
    case right = "right"

    var id: Self { self }

    var displayName: String {
        switch self {
        case .left:
            return "Left"
        case .right:
            return "Right"
        }
    }
}

enum AssistantNotchHoverDelay: String, CaseIterable, Identifiable, Codable {
    case off = "off"
    case oneSecond = "1s"
    case twoSeconds = "2s"
    case threeSeconds = "3s"

    var id: Self { self }

    var displayName: String {
        switch self {
        case .off:
            return "Off"
        case .oneSecond:
            return "1 second"
        case .twoSeconds:
            return "2 seconds"
        case .threeSeconds:
            return "3 seconds"
        }
    }

    var seconds: TimeInterval {
        switch self {
        case .off:
            return 0
        case .oneSecond:
            return 1
        case .twoSeconds:
            return 2
        case .threeSeconds:
            return 3
        }
    }
}

struct ColorPalette {
    let baseTint: Color
    let accentTint: Color
    let canvasBase: Color
    let canvasDeep: Color
    let sidebarTint: Color
    let panelTint: Color
    let rowSelection: Color
    let historyTint: Color
    let aiStudioTint: Color
    let settingsTint: Color
    let glowWarm: Color
    let glowCool: Color
    let surfaceTop: Color
    let surfaceBottom: Color
}

enum ColorTheme: String, CaseIterable, Identifiable {
    case ocean = "Ocean"
    case violet = "Violet"
    case midnight = "Midnight"
    case forest = "Forest"
    case rose = "Rose"
    case sunset = "Sunset"
    case arctic = "Arctic"
    case slate = "Slate"
    case amethyst = "Amethyst"
    case noirGold = "Noir Gold"

    var id: Self { self }
    var displayName: String { rawValue }

    var palette: ColorPalette {
        switch self {
        case .ocean:
            return ColorPalette(
                baseTint: Color(red: 0.08, green: 0.14, blue: 0.24),
                accentTint: Color(red: 0.30, green: 0.62, blue: 0.70),
                canvasBase: Color(red: 0.06, green: 0.10, blue: 0.18),
                canvasDeep: Color(red: 0.03, green: 0.05, blue: 0.10),
                sidebarTint: Color(red: 0.08, green: 0.13, blue: 0.22),
                panelTint: Color(red: 0.07, green: 0.11, blue: 0.20),
                rowSelection: Color(red: 0.16, green: 0.28, blue: 0.42),
                historyTint: Color(red: 0.78, green: 0.64, blue: 0.22),
                aiStudioTint: Color(red: 0.30, green: 0.62, blue: 0.70),
                settingsTint: Color(red: 0.82, green: 0.68, blue: 0.28),
                glowWarm: Color(red: 0.82, green: 0.68, blue: 0.28),
                glowCool: Color(red: 0.25, green: 0.58, blue: 0.66),
                surfaceTop: Color(red: 0.10, green: 0.16, blue: 0.28),
                surfaceBottom: Color(red: 0.06, green: 0.10, blue: 0.18)
            )
        case .violet:
            return ColorPalette(
                baseTint: Color(red: 0.24, green: 0.20, blue: 0.34),
                accentTint: Color(red: 0.35, green: 0.58, blue: 0.95),
                canvasBase: Color(red: 0.09, green: 0.08, blue: 0.15),
                canvasDeep: Color(red: 0.04, green: 0.04, blue: 0.08),
                sidebarTint: Color(red: 0.17, green: 0.14, blue: 0.23),
                panelTint: Color(red: 0.13, green: 0.11, blue: 0.20),
                rowSelection: Color(red: 0.29, green: 0.33, blue: 0.39),
                historyTint: Color(red: 0.54, green: 0.61, blue: 0.57),
                aiStudioTint: Color(red: 0.60, green: 0.64, blue: 0.71),
                settingsTint: Color(red: 0.84, green: 0.47, blue: 0.40),
                glowWarm: Color(red: 0.88, green: 0.30, blue: 0.37),
                glowCool: Color(red: 0.19, green: 0.42, blue: 0.95),
                surfaceTop: Color(red: 0.18, green: 0.15, blue: 0.27),
                surfaceBottom: Color(red: 0.08, green: 0.08, blue: 0.16)
            )
        case .midnight:
            return ColorPalette(
                baseTint: Color(red: 0.08, green: 0.08, blue: 0.16),
                accentTint: Color(red: 0.30, green: 0.50, blue: 0.95),
                canvasBase: Color(red: 0.06, green: 0.06, blue: 0.13),
                canvasDeep: Color(red: 0.02, green: 0.02, blue: 0.06),
                sidebarTint: Color(red: 0.08, green: 0.08, blue: 0.18),
                panelTint: Color(red: 0.07, green: 0.07, blue: 0.16),
                rowSelection: Color(red: 0.16, green: 0.20, blue: 0.40),
                historyTint: Color(red: 0.45, green: 0.60, blue: 0.95),
                aiStudioTint: Color(red: 0.30, green: 0.50, blue: 0.95),
                settingsTint: Color(red: 0.55, green: 0.65, blue: 0.95),
                glowWarm: Color(red: 0.40, green: 0.45, blue: 0.90),
                glowCool: Color(red: 0.20, green: 0.30, blue: 0.80),
                surfaceTop: Color(red: 0.10, green: 0.10, blue: 0.24),
                surfaceBottom: Color(red: 0.05, green: 0.05, blue: 0.14)
            )
        case .forest:
            return ColorPalette(
                baseTint: Color(red: 0.06, green: 0.14, blue: 0.10),
                accentTint: Color(red: 0.28, green: 0.70, blue: 0.45),
                canvasBase: Color(red: 0.05, green: 0.11, blue: 0.08),
                canvasDeep: Color(red: 0.02, green: 0.06, blue: 0.04),
                sidebarTint: Color(red: 0.07, green: 0.15, blue: 0.11),
                panelTint: Color(red: 0.06, green: 0.13, blue: 0.09),
                rowSelection: Color(red: 0.14, green: 0.30, blue: 0.22),
                historyTint: Color(red: 0.82, green: 0.65, blue: 0.28),
                aiStudioTint: Color(red: 0.28, green: 0.70, blue: 0.45),
                settingsTint: Color(red: 0.82, green: 0.65, blue: 0.28),
                glowWarm: Color(red: 0.78, green: 0.62, blue: 0.24),
                glowCool: Color(red: 0.20, green: 0.58, blue: 0.38),
                surfaceTop: Color(red: 0.08, green: 0.18, blue: 0.13),
                surfaceBottom: Color(red: 0.04, green: 0.10, blue: 0.07)
            )
        case .rose:
            return ColorPalette(
                baseTint: Color(red: 0.16, green: 0.06, blue: 0.12),
                accentTint: Color(red: 0.85, green: 0.45, blue: 0.58),
                canvasBase: Color(red: 0.12, green: 0.05, blue: 0.10),
                canvasDeep: Color(red: 0.06, green: 0.02, blue: 0.05),
                sidebarTint: Color(red: 0.18, green: 0.08, blue: 0.14),
                panelTint: Color(red: 0.15, green: 0.06, blue: 0.12),
                rowSelection: Color(red: 0.32, green: 0.14, blue: 0.24),
                historyTint: Color(red: 0.90, green: 0.60, blue: 0.68),
                aiStudioTint: Color(red: 0.85, green: 0.45, blue: 0.58),
                settingsTint: Color(red: 0.90, green: 0.55, blue: 0.50),
                glowWarm: Color(red: 0.85, green: 0.40, blue: 0.50),
                glowCool: Color(red: 0.60, green: 0.30, blue: 0.55),
                surfaceTop: Color(red: 0.20, green: 0.09, blue: 0.16),
                surfaceBottom: Color(red: 0.12, green: 0.05, blue: 0.10)
            )
        case .sunset:
            return ColorPalette(
                baseTint: Color(red: 0.16, green: 0.10, blue: 0.06),
                accentTint: Color(red: 0.92, green: 0.55, blue: 0.25),
                canvasBase: Color(red: 0.12, green: 0.08, blue: 0.05),
                canvasDeep: Color(red: 0.06, green: 0.04, blue: 0.02),
                sidebarTint: Color(red: 0.18, green: 0.12, blue: 0.08),
                panelTint: Color(red: 0.15, green: 0.10, blue: 0.06),
                rowSelection: Color(red: 0.30, green: 0.20, blue: 0.14),
                historyTint: Color(red: 0.95, green: 0.70, blue: 0.30),
                aiStudioTint: Color(red: 0.92, green: 0.55, blue: 0.25),
                settingsTint: Color(red: 0.95, green: 0.65, blue: 0.25),
                glowWarm: Color(red: 0.92, green: 0.50, blue: 0.20),
                glowCool: Color(red: 0.70, green: 0.35, blue: 0.18),
                surfaceTop: Color(red: 0.20, green: 0.14, blue: 0.09),
                surfaceBottom: Color(red: 0.12, green: 0.08, blue: 0.05)
            )
        case .arctic:
            return ColorPalette(
                baseTint: Color(red: 0.08, green: 0.12, blue: 0.16),
                accentTint: Color(red: 0.40, green: 0.78, blue: 0.90),
                canvasBase: Color(red: 0.07, green: 0.10, blue: 0.14),
                canvasDeep: Color(red: 0.03, green: 0.05, blue: 0.07),
                sidebarTint: Color(red: 0.09, green: 0.14, blue: 0.18),
                panelTint: Color(red: 0.08, green: 0.12, blue: 0.16),
                rowSelection: Color(red: 0.18, green: 0.28, blue: 0.36),
                historyTint: Color(red: 0.50, green: 0.82, blue: 0.92),
                aiStudioTint: Color(red: 0.40, green: 0.78, blue: 0.90),
                settingsTint: Color(red: 0.55, green: 0.80, blue: 0.88),
                glowWarm: Color(red: 0.50, green: 0.75, blue: 0.85),
                glowCool: Color(red: 0.30, green: 0.60, blue: 0.78),
                surfaceTop: Color(red: 0.11, green: 0.16, blue: 0.22),
                surfaceBottom: Color(red: 0.06, green: 0.09, blue: 0.13)
            )
        case .slate:
            return ColorPalette(
                baseTint: Color(red: 0.12, green: 0.12, blue: 0.14),
                accentTint: Color(red: 0.68, green: 0.70, blue: 0.74),
                canvasBase: Color(red: 0.10, green: 0.10, blue: 0.12),
                canvasDeep: Color(red: 0.05, green: 0.05, blue: 0.06),
                sidebarTint: Color(red: 0.13, green: 0.13, blue: 0.16),
                panelTint: Color(red: 0.11, green: 0.11, blue: 0.14),
                rowSelection: Color(red: 0.24, green: 0.24, blue: 0.28),
                historyTint: Color(red: 0.72, green: 0.74, blue: 0.78),
                aiStudioTint: Color(red: 0.60, green: 0.62, blue: 0.68),
                settingsTint: Color(red: 0.70, green: 0.72, blue: 0.76),
                glowWarm: Color(red: 0.60, green: 0.58, blue: 0.55),
                glowCool: Color(red: 0.45, green: 0.48, blue: 0.55),
                surfaceTop: Color(red: 0.16, green: 0.16, blue: 0.20),
                surfaceBottom: Color(red: 0.09, green: 0.09, blue: 0.12)
            )
        case .amethyst:
            return ColorPalette(
                baseTint: Color(red: 0.14, green: 0.08, blue: 0.20),
                accentTint: Color(red: 0.62, green: 0.42, blue: 0.85),
                canvasBase: Color(red: 0.10, green: 0.06, blue: 0.16),
                canvasDeep: Color(red: 0.05, green: 0.03, blue: 0.08),
                sidebarTint: Color(red: 0.15, green: 0.09, blue: 0.22),
                panelTint: Color(red: 0.13, green: 0.07, blue: 0.20),
                rowSelection: Color(red: 0.26, green: 0.16, blue: 0.38),
                historyTint: Color(red: 0.72, green: 0.55, blue: 0.90),
                aiStudioTint: Color(red: 0.62, green: 0.42, blue: 0.85),
                settingsTint: Color(red: 0.75, green: 0.50, blue: 0.85),
                glowWarm: Color(red: 0.65, green: 0.40, blue: 0.80),
                glowCool: Color(red: 0.45, green: 0.28, blue: 0.70),
                surfaceTop: Color(red: 0.18, green: 0.10, blue: 0.28),
                surfaceBottom: Color(red: 0.10, green: 0.06, blue: 0.16)
            )
        case .noirGold:
            return ColorPalette(
                baseTint: Color(red: 0.10, green: 0.09, blue: 0.07),
                accentTint: Color(red: 0.79, green: 0.66, blue: 0.30),
                canvasBase: Color(red: 0.06, green: 0.06, blue: 0.05),
                canvasDeep: Color(red: 0.03, green: 0.03, blue: 0.02),
                sidebarTint: Color(red: 0.10, green: 0.09, blue: 0.07),
                panelTint: Color(red: 0.08, green: 0.07, blue: 0.06),
                rowSelection: Color(red: 0.22, green: 0.18, blue: 0.10),
                historyTint: Color(red: 0.91, green: 0.83, blue: 0.55),
                aiStudioTint: Color(red: 0.79, green: 0.66, blue: 0.30),
                settingsTint: Color(red: 0.85, green: 0.72, blue: 0.35),
                glowWarm: Color(red: 0.79, green: 0.66, blue: 0.30),
                glowCool: Color(red: 0.55, green: 0.46, blue: 0.22),
                surfaceTop: Color(red: 0.14, green: 0.12, blue: 0.09),
                surfaceBottom: Color(red: 0.06, green: 0.05, blue: 0.04)
            )
        }
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
    static let accessibilityTrustDidBecomeGrantedNotification = Notification.Name(
        "OpenAssist.accessibilityTrustDidBecomeGranted"
    )
    static let noDictationSoundName = "None"
    static let dictationStartSoundOptions = [
        noDictationSoundName,
        "Basso",
        "Blow",
        "Bottle",
        "Frog",
        "Funk",
        "Glass",
        "Hero",
        "Ping",
        "Pop",
        "Purr",
        "Sosumi",
        "Submarine",
        "Tink"
    ]
    static let defaultDictationStartSoundName = "Ping"
    static let defaultDictationStopSoundName = "Glass"
    static let defaultDictationProcessingSoundName = "Ping"
    static let defaultDictationPastedSoundName = "Pop"
    static let defaultDictationCorrectionLearnedSoundName = "Purr"
    static let defaultDictationFeedbackVolume: Double = 0.10
    static let defaultAutomationAPIPort: UInt16 = 45831
    nonisolated static let crossIDEConversationSharingMigrationDefaultsKey =
        "OpenAssist.migration.crossIDEConversationSharingDefaultedV1"

    private let defaults = UserDefaults.standard
    private var isApplyingChanges = false
    private var pendingOnChangeWorkItem: DispatchWorkItem?
    private static let onChangeDebounceSeconds: TimeInterval = 0.14

    private enum Keys {
        static let shortcutKeyCode = "OpenAssist.shortcutKeyCode"
        static let shortcutModifiers = "OpenAssist.shortcutModifiers"
        static let muteSystemSoundsWhileHoldingShortcut = "OpenAssist.muteSystemSoundsWhileHoldingShortcut"
        static let continuousMode = "OpenAssist.continuousMode" // legacy key kept for migration safety
        static let continuousToggleShortcutKeyCode = "OpenAssist.continuousToggleShortcutKeyCode"
        static let continuousToggleShortcutModifiers = "OpenAssist.continuousToggleShortcutModifiers"
        static let assistantLiveVoiceShortcutKeyCode = "OpenAssist.assistantLiveVoiceShortcutKeyCode"
        static let assistantLiveVoiceShortcutModifiers = "OpenAssist.assistantLiveVoiceShortcutModifiers"
        static let assistantCompactShortcutKeyCode = "OpenAssist.assistantCompactShortcutKeyCode"
        static let assistantCompactShortcutModifiers = "OpenAssist.assistantCompactShortcutModifiers"
        static let autoDetectMicrophone = "OpenAssist.autoDetectMicrophone"
        static let selectedMicrophoneUID = "OpenAssist.selectedMicrophoneUID"
        static let copyToClipboard = "OpenAssist.copyToClipboard"
        static let insertionDiagnosticsEnabled = "OpenAssist.insertionDiagnosticsEnabled"
        static let enableContextualBias = "OpenAssist.enableContextualBias"
        static let keepTextAcrossPauses = "OpenAssist.keepTextAcrossPauses"
        static let preferOnDeviceRecognition = "OpenAssist.preferOnDeviceRecognition" // legacy key for migration
        static let recognitionMode = "OpenAssist.recognitionMode"
        static let finalizeDelaySeconds = "OpenAssist.finalizeDelaySeconds"
        static let customContextPhrases = "OpenAssist.customContextPhrases"
        static let textCleanupMode = "OpenAssist.textCleanupMode"
        static let autoPunctuation = "OpenAssist.autoPunctuation"
        static let waveformTheme = "OpenAssist.waveformTheme"
        static let appChromeStyle = "OpenAssist.appChromeStyle"
        static let colorTheme = "OpenAssist.colorTheme"
        static let transcriptionEngine = "OpenAssist.transcriptionEngine"
        static let cloudTranscriptionProvider = "OpenAssist.cloudTranscriptionProvider"
        static let cloudTranscriptionModel = "OpenAssist.cloudTranscriptionModel"
        static let cloudTranscriptionBaseURL = "OpenAssist.cloudTranscriptionBaseURL"
        static let cloudTranscriptionRequestTimeoutSeconds = "OpenAssist.cloudTranscriptionRequestTimeoutSeconds"
        static let selectedWhisperModelID = "OpenAssist.selectedWhisperModelID"
        static let whisperUseCoreML = "OpenAssist.whisperUseCoreML"
        static let whisperAutoUnloadIdleContextEnabled = "OpenAssist.whisperAutoUnloadIdleContextEnabled"
        static let whisperIdleContextUnloadSeconds = "OpenAssist.whisperIdleContextUnloadSeconds"
        static let adaptiveCorrectionsEnabled = "OpenAssist.adaptiveCorrectionsEnabled"
        static let playCorrectionLearnedSound = "OpenAssist.playCorrectionLearnedSound"
        static let dictationStartSoundName = "OpenAssist.dictationStartSoundName"
        static let dictationStopSoundName = "OpenAssist.dictationStopSoundName"
        static let dictationProcessingSoundName = "OpenAssist.dictationProcessingSoundName"
        static let dictationPastedSoundName = "OpenAssist.dictationPastedSoundName"
        static let dictationCorrectionLearnedSoundName = "OpenAssist.dictationCorrectionLearnedSoundName"
        static let dictationFeedbackVolume = "OpenAssist.dictationFeedbackVolume"
        static let automationAPIEnabled = "OpenAssist.automationAPIEnabled"
        static let automationAPIPort = "OpenAssist.automationAPIPort"
        static let automationAPINotificationsEnabled = "OpenAssist.automationAPINotificationsEnabled"
        static let automationAPISpeechEnabled = "OpenAssist.automationAPISpeechEnabled"
        static let automationAPISoundEnabled = "OpenAssist.automationAPISoundEnabled"
        static let automationAPIDefaultVoiceIdentifier = "OpenAssist.automationAPIDefaultVoiceIdentifier"
        static let automationAPIDefaultSound = "OpenAssist.automationAPIDefaultSound"
        static let automationClaudeEnabled = "OpenAssist.automationClaudeEnabled"
        static let automationCodexCLIEnabled = "OpenAssist.automationCodexCLIEnabled"
        static let automationCodexCloudEnabled = "OpenAssist.automationCodexCloudEnabled"
        static let telegramRemoteEnabled = "OpenAssist.telegramRemoteEnabled"
        static let telegramOwnerUserID = "OpenAssist.telegramOwnerUserID"
        static let telegramOwnerChatID = "OpenAssist.telegramOwnerChatID"
        static let telegramPendingUserID = "OpenAssist.telegramPendingUserID"
        static let telegramPendingChatID = "OpenAssist.telegramPendingChatID"
        static let telegramPendingDisplayName = "OpenAssist.telegramPendingDisplayName"
        static let telegramLastProcessedUpdateID = "OpenAssist.telegramLastProcessedUpdateID"
        static let telegramTrackedMessageIDs = "OpenAssist.telegramTrackedMessageIDs"
        static let promptRewriteEnabled = "OpenAssist.promptRewriteEnabled"
        static let promptRewriteAutoInsertEnabled = "OpenAssist.promptRewriteAutoInsertEnabled"
        static let memoryIndexingEnabled = "OpenAssist.memoryIndexingEnabled"
        static let memoryProviderCatalogAutoUpdate = "OpenAssist.memoryProviderCatalogAutoUpdate"
        static let memoryDetectedProviderIDs = "OpenAssist.memoryDetectedProviderIDs"
        static let memoryEnabledProviderIDs = "OpenAssist.memoryEnabledProviderIDs"
        static let memoryDetectedSourceFolderIDs = "OpenAssist.memoryDetectedSourceFolderIDs"
        static let memoryEnabledSourceFolderIDs = "OpenAssist.memoryEnabledSourceFolderIDs"
        static let promptRewriteProviderMode = "OpenAssist.promptRewriteProviderMode"
        static let promptRewriteOpenAIModel = "OpenAssist.promptRewriteOpenAIModel"
        static let promptRewriteOpenAIBaseURL = "OpenAssist.promptRewriteOpenAIBaseURL"
        static let promptRewriteModelByProvider = "OpenAssist.promptRewriteModelByProvider"
        static let promptRewriteBaseURLByProvider = "OpenAssist.promptRewriteBaseURLByProvider"
        static let promptRewriteRequestTimeoutSeconds = "OpenAssist.promptRewriteRequestTimeoutSeconds"
        static let promptRewriteAlwaysConvertToMarkdown = "OpenAssist.promptRewriteAlwaysConvertToMarkdown"
        static let promptRewriteStylePreset = "OpenAssist.promptRewriteStylePreset"
        static let promptRewriteCustomStyleInstructions = "OpenAssist.promptRewriteCustomStyleInstructions"
        static let promptRewriteConversationHistoryEnabled = "OpenAssist.promptRewriteConversationHistoryEnabled"
        static let promptRewriteConversationTimeoutMinutes = "OpenAssist.promptRewriteConversationTimeoutMinutes"
        static let promptRewriteConversationTurnLimit = "OpenAssist.promptRewriteConversationTurnLimit"
        static let promptRewriteConversationPinnedContextID = "OpenAssist.promptRewriteConversationPinnedContextID"
        static let promptRewriteConversationHistoryDisabledContextIDs = "OpenAssist.promptRewriteConversationHistoryDisabledContextIDs"
        static let promptRewriteCrossIDEConversationSharingEnabled = "OpenAssist.promptRewriteCrossIDEConversationSharingEnabled"
        static let promptRewriteCrossIDEConversationSharingDefaultedMigrationV1 = SettingsStore.crossIDEConversationSharingMigrationDefaultsKey
        static let googleAIStudioImageGenerationModel = "OpenAssist.googleAIStudioImageGenerationModel"
        static let localAISetupCompleted = "OpenAssist.localAISetupCompleted"
        static let localAISelectedModelID = "OpenAssist.localAISelectedModelID"
        static let localAIManagedRuntimeEnabled = "OpenAssist.localAIManagedRuntimeEnabled"
        static let localAIRuntimeVersion = "OpenAssist.localAIRuntimeVersion"
        static let localAILastHealthCheckEpoch = "OpenAssist.localAILastHealthCheckEpoch"
        static let assistantBetaEnabled = "OpenAssist.assistantBetaEnabled"
        static let assistantVoiceTaskEntryEnabled = "OpenAssist.assistantVoiceTaskEntryEnabled"
        static let assistantFloatingHUDEnabled = "OpenAssist.assistantFloatingHUDEnabled"
        static let assistantCompactPresentationStyle = "OpenAssist.assistantCompactPresentationStyle"
        static let assistantCompactSidebarEdge = "OpenAssist.assistantCompactSidebarEdge"
        static let assistantCompactSidebarPinned = "OpenAssist.assistantCompactSidebarPinned"
        static let assistantNotchHoverDelay = "OpenAssist.assistantNotchHoverDelay"
        static let assistantBetaWarningAcknowledged = "OpenAssist.assistantBetaWarningAcknowledged"
        static let assistantVoiceOutputEnabled = "OpenAssist.assistantVoiceOutputEnabled"
        static let assistantVoiceEngine = "OpenAssist.assistantVoiceEngine"
        static let assistantHumeVoiceID = "OpenAssist.assistantHumeVoiceID"
        static let assistantHumeVoiceName = "OpenAssist.assistantHumeVoiceName"
        static let assistantHumeVoiceSource = "OpenAssist.assistantHumeVoiceSource"
        static let assistantHumeConversationConfigID = "OpenAssist.assistantHumeConversationConfigID"
        static let assistantHumeConversationConfigVersion = "OpenAssist.assistantHumeConversationConfigVersion"
        static let assistantTTSFallbackToMacOS = "OpenAssist.assistantTTSFallbackToMacOS"
        static let assistantTTSFallbackVoiceIdentifier = "OpenAssist.assistantTTSFallbackVoiceIdentifier"
        static let assistantInterruptCurrentSpeechOnNewReply = "OpenAssist.assistantInterruptCurrentSpeechOnNewReply"
        static let assistantBackend = "OpenAssist.assistantBackend"
        static let assistantPreferredModelID = "OpenAssist.assistantPreferredModelID"
        static let assistantPreferredSubagentModelID = "OpenAssist.assistantPreferredSubagentModelID"
        static let assistantOwnedThreadIDs = "OpenAssist.assistantOwnedThreadIDs"
        static let assistantArchiveDefaultRetentionHours = "OpenAssist.assistantArchiveDefaultRetentionHours"
        static let browserAutomationEnabled = "OpenAssist.browserAutomationEnabled"
        static let assistantComputerUseEnabled = "OpenAssist.assistantComputerUseEnabled"
        static let browserSelectedProfileID = "OpenAssist.browserSelectedProfileID"
        static let settingsLastViewedSection = "OpenAssist.settingsLastViewedSection"
        static let settingsGettingStartedDismissed = "OpenAssist.settingsGettingStartedDismissed"
        static let assistantAlwaysApprovedToolKinds = "OpenAssist.assistantAlwaysApprovedToolKinds"
        static let assistantConversationalToolUsePreference = "OpenAssist.assistantConversationalToolUsePreference"
        static let assistantCustomInstructions = "OpenAssist.assistantCustomInstructions"
        static let assistantMaxToolCallsPerTurn = "OpenAssist.assistantMaxToolCallsPerTurn"
        static let assistantMaxRepeatedCommandAttemptsPerTurn = "OpenAssist.assistantMaxRepeatedCommandAttemptsPerTurn"
        static let assistantTrackCodeChangesInGitRepos = "OpenAssist.assistantTrackCodeChangesInGitRepos"
        static let assistantMemoryEnabled = "OpenAssist.assistantMemoryEnabled"
        static let assistantMemoryReviewEnabled = "OpenAssist.assistantMemoryReviewEnabled"
        static let assistantMemorySummaryMaxChars = "OpenAssist.assistantMemorySummaryMaxChars"
        static let assistantNotesBackupFolderPath = "OpenAssist.assistantNotesBackupFolderPath"
        static let assistantNotesLastSuccessfulBackupEpoch = "OpenAssist.assistantNotesLastSuccessfulBackupEpoch"
    }

    private enum ContinuousToggleDefaults {
        static let keyCode: UInt16 = 49 // Space
        static let modifiers: UInt = NSEvent.ModifierFlags([.command, .option, .control]).rawValue
    }

    private enum AssistantLiveVoiceShortcutDefaults {
        static let keyCode: UInt16 = 37 // L
        static let modifiers: UInt = NSEvent.ModifierFlags([.command, .option, .control]).rawValue
    }

    private enum AssistantCompactShortcutDefaults {
        static let keyCode: UInt16 = 1 // S
        static let modifiers: UInt = NSEvent.ModifierFlags([.command, .option, .control]).rawValue
    }

    private enum PasteLastShortcut {
        static let keyCode: UInt16 = 9 // V
        static let modifiers: UInt = NSEvent.ModifierFlags([.command, .option]).rawValue
    }

    private enum PromptRewriteRequestTimeoutDefaults {
        static let minimumSeconds: Double = 3
        static let maximumSeconds: Double = 120
        static let fallbackSeconds: Double = 8
    }

    private enum CloudTranscriptionRequestTimeoutDefaults {
        static let minimumSeconds: Double = 5
        static let maximumSeconds: Double = 180
        static let fallbackSeconds: Double = 30
    }

    private enum WhisperContextRetentionDefaults {
        static let minimumSeconds: Double = 30
        static let maximumSeconds: Double = 3600
        static let fallbackSeconds: Double = 8 * 60
    }

    private var promptRewriteModelByProvider: [String: String] = [:]
    private var promptRewriteBaseURLByProvider: [String: String] = [:]
    private var saveSuppressionDepth = 0

    @Published var shortcutKeyCode: UInt16 {
        didSet {
            save()
        }
    }

    @Published var shortcutModifiers: UInt {
        didSet {
            save()
        }
    }

    @Published var continuousToggleShortcutKeyCode: UInt16 {
        didSet {
            save()
        }
    }

    @Published var continuousToggleShortcutModifiers: UInt {
        didSet {
            save()
        }
    }

    @Published var assistantLiveVoiceShortcutKeyCode: UInt16 {
        didSet {
            save()
        }
    }

    @Published var assistantLiveVoiceShortcutModifiers: UInt {
        didSet {
            save()
        }
    }

    @Published var assistantCompactShortcutKeyCode: UInt16 {
        didSet {
            save()
        }
    }

    @Published var assistantCompactShortcutModifiers: UInt {
        didSet {
            save()
        }
    }

    @Published var muteSystemSoundsWhileHoldingShortcut: Bool {
        didSet {
            save()
        }
    }

    @Published var autoDetectMicrophone: Bool {
        didSet {
            guard oldValue != autoDetectMicrophone else { return }
            if autoDetectMicrophone && !selectedMicrophoneUID.isEmpty {
                selectedMicrophoneUID = ""
            }
            save()
        }
    }

    @Published var selectedMicrophoneUID: String {
        didSet {
            guard oldValue != selectedMicrophoneUID else { return }
            save()
        }
    }

    @Published var copyToClipboard: Bool {
        didSet {
            save()
        }
    }

    @Published var insertionDiagnosticsEnabled: Bool {
        didSet {
            save()
        }
    }

    @Published var enableContextualBias: Bool {
        didSet {
            save()
        }
    }

    @Published var keepTextAcrossPauses: Bool {
        didSet {
            save()
        }
    }

    @Published var recognitionModeRawValue: String {
        didSet {
            save()
        }
    }

    @Published var finalizeDelaySeconds: Double {
        didSet {
            save()
        }
    }

    @Published var customContextPhrases: String {
        didSet {
            save()
        }
    }

    @Published var textCleanupModeRawValue: String {
        didSet {
            save()
        }
    }

    @Published var autoPunctuation: Bool {
        didSet {
            save()
        }
    }

    @Published var waveformThemeRawValue: String {
        didSet {
            save()
        }
    }

    @Published var appChromeStyleRawValue: String {
        didSet {
            save()
        }
    }

    @Published var colorThemeRawValue: String {
        didSet {
            save()
        }
    }

    @Published var transcriptionEngineRawValue: String {
        didSet {
            save()
        }
    }

    @Published var cloudTranscriptionProviderRawValue: String {
        didSet {
            if oldValue != cloudTranscriptionProviderRawValue {
                cloudTranscriptionAPIKey = Self.loadCloudTranscriptionProviderAPIKey(for: cloudTranscriptionProvider)
                applyCloudTranscriptionProviderDefaultsIfNeeded(force: true)
            }
            save()
        }
    }

    @Published var cloudTranscriptionModel: String {
        didSet {
            let normalized = Self.normalizedIdentifier(cloudTranscriptionModel)
            if normalized != cloudTranscriptionModel {
                cloudTranscriptionModel = normalized
                return
            }
            save()
        }
    }

    @Published var cloudTranscriptionBaseURL: String {
        didSet {
            let normalized = Self.normalizedIdentifier(cloudTranscriptionBaseURL)
            if normalized != cloudTranscriptionBaseURL {
                cloudTranscriptionBaseURL = normalized
                return
            }
            save()
        }
    }

    @Published var cloudTranscriptionRequestTimeoutSeconds: Double {
        didSet {
            let normalized = min(
                CloudTranscriptionRequestTimeoutDefaults.maximumSeconds,
                max(CloudTranscriptionRequestTimeoutDefaults.minimumSeconds, cloudTranscriptionRequestTimeoutSeconds)
            )
            guard normalized == cloudTranscriptionRequestTimeoutSeconds else {
                cloudTranscriptionRequestTimeoutSeconds = normalized
                return
            }
            save()
        }
    }

    @Published var cloudTranscriptionAPIKey: String {
        didSet {
            Self.storeCloudTranscriptionProviderAPIKey(
                cloudTranscriptionAPIKey,
                for: cloudTranscriptionProvider
            )
            if cloudTranscriptionProvider == .gemini,
               googleAIStudioAPIKey != cloudTranscriptionAPIKey {
                googleAIStudioAPIKey = cloudTranscriptionAPIKey
            }
            save()
        }
    }

    @Published var selectedWhisperModelID: String {
        didSet {
            guard oldValue != selectedWhisperModelID else { return }
            save()
        }
    }

    @Published var whisperUseCoreML: Bool {
        didSet {
            save()
        }
    }

    @Published var whisperAutoUnloadIdleContextEnabled: Bool {
        didSet {
            save()
        }
    }

    @Published var whisperIdleContextUnloadSeconds: Double {
        didSet {
            let normalized = min(
                WhisperContextRetentionDefaults.maximumSeconds,
                max(WhisperContextRetentionDefaults.minimumSeconds, whisperIdleContextUnloadSeconds)
            )
            guard normalized == whisperIdleContextUnloadSeconds else {
                whisperIdleContextUnloadSeconds = normalized
                return
            }
            save()
        }
    }

    @Published var adaptiveCorrectionsEnabled: Bool {
        didSet {
            save()
        }
    }

    @Published var playCorrectionLearnedSound: Bool {
        didSet {
            save()
        }
    }

    @Published var dictationStartSoundName: String {
        didSet {
            save()
        }
    }

    @Published var dictationStopSoundName: String {
        didSet {
            save()
        }
    }

    @Published var dictationProcessingSoundName: String {
        didSet {
            save()
        }
    }

    @Published var dictationPastedSoundName: String {
        didSet {
            save()
        }
    }

    @Published var dictationCorrectionLearnedSoundName: String {
        didSet {
            save()
        }
    }

    @Published var dictationFeedbackVolume: Double {
        didSet {
            save()
        }
    }

    @Published var automationAPIEnabled: Bool {
        didSet {
            if automationAPIEnabled {
                ensureAutomationAPIToken()
            }
            save()
        }
    }

    @Published var automationAPIPort: UInt16 {
        didSet {
            let normalized = UInt16(min(Int(UInt16.max), max(1024, Int(automationAPIPort))))
            guard normalized == automationAPIPort else {
                automationAPIPort = normalized
                return
            }
            save()
        }
    }

    @Published var automationAPINotificationsEnabled: Bool {
        didSet {
            save()
        }
    }

    @Published var automationAPISpeechEnabled: Bool {
        didSet {
            save()
        }
    }

    @Published var automationAPISoundEnabled: Bool {
        didSet {
            save()
        }
    }

    @Published var automationAPIDefaultVoiceIdentifier: String {
        didSet {
            let normalized = Self.normalizedIdentifier(automationAPIDefaultVoiceIdentifier)
            guard normalized == automationAPIDefaultVoiceIdentifier else {
                automationAPIDefaultVoiceIdentifier = normalized
                return
            }
            save()
        }
    }

    @Published var automationAPIDefaultSoundRawValue: String {
        didSet {
            if AutomationAPISound(rawValue: automationAPIDefaultSoundRawValue) == nil {
                automationAPIDefaultSoundRawValue = AutomationAPISound.processing.rawValue
                return
            }
            save()
        }
    }

    @Published var automationClaudeEnabled: Bool {
        didSet {
            save()
        }
    }

    @Published var automationCodexCLIEnabled: Bool {
        didSet {
            save()
        }
    }

    @Published var automationCodexCloudEnabled: Bool {
        didSet {
            save()
        }
    }

    @Published var telegramRemoteEnabled: Bool {
        didSet {
            save()
        }
    }

    @Published var telegramOwnerUserID: String {
        didSet {
            let normalized = Self.normalizedIdentifier(telegramOwnerUserID)
            guard normalized == telegramOwnerUserID else {
                telegramOwnerUserID = normalized
                return
            }
            save()
        }
    }

    @Published var telegramOwnerChatID: String {
        didSet {
            let normalized = Self.normalizedIdentifier(telegramOwnerChatID)
            guard normalized == telegramOwnerChatID else {
                telegramOwnerChatID = normalized
                return
            }
            save()
        }
    }

    @Published var telegramPendingUserID: String {
        didSet {
            let normalized = Self.normalizedIdentifier(telegramPendingUserID)
            guard normalized == telegramPendingUserID else {
                telegramPendingUserID = normalized
                return
            }
            save()
        }
    }

    @Published var telegramPendingChatID: String {
        didSet {
            let normalized = Self.normalizedIdentifier(telegramPendingChatID)
            guard normalized == telegramPendingChatID else {
                telegramPendingChatID = normalized
                return
            }
            save()
        }
    }

    @Published var telegramPendingDisplayName: String {
        didSet {
            save()
        }
    }

    @Published var promptRewriteEnabled: Bool {
        didSet {
            save()
        }
    }

    @Published var promptRewriteAutoInsertEnabled: Bool {
        didSet {
            save()
        }
    }

    @Published var memoryIndexingEnabled: Bool {
        didSet {
            save()
        }
    }

    @Published var memoryProviderCatalogAutoUpdate: Bool {
        didSet {
            save()
        }
    }

    @Published var memoryDetectedProviderIDs: [String] {
        didSet {
            let normalized = Self.normalizedStringList(memoryDetectedProviderIDs)
            guard normalized == memoryDetectedProviderIDs else {
                memoryDetectedProviderIDs = normalized
                return
            }
            save()
        }
    }

    @Published var memoryEnabledProviderIDs: [String] {
        didSet {
            let normalized = Self.normalizedStringList(memoryEnabledProviderIDs)
            guard normalized == memoryEnabledProviderIDs else {
                memoryEnabledProviderIDs = normalized
                return
            }
            save()
        }
    }

    @Published var memoryDetectedSourceFolderIDs: [String] {
        didSet {
            let normalized = Self.normalizedStringList(memoryDetectedSourceFolderIDs)
            guard normalized == memoryDetectedSourceFolderIDs else {
                memoryDetectedSourceFolderIDs = normalized
                return
            }
            save()
        }
    }

    @Published var memoryEnabledSourceFolderIDs: [String] {
        didSet {
            let normalized = Self.normalizedStringList(memoryEnabledSourceFolderIDs)
            guard normalized == memoryEnabledSourceFolderIDs else {
                memoryEnabledSourceFolderIDs = normalized
                return
            }
            save()
        }
    }

    @Published var promptRewriteProviderModeRawValue: String {
        didSet {
            if oldValue != promptRewriteProviderModeRawValue {
                persistPromptRewriteProviderConfiguration(forRawValue: oldValue)
                restorePromptRewriteProviderConfiguration(for: promptRewriteProviderMode)
                promptRewriteOpenAIAPIKey = Self.loadPromptRewriteProviderAPIKey(for: promptRewriteProviderMode)
            }
            save()
        }
    }

    @Published var promptRewriteOpenAIModel: String {
        didSet {
            let normalized = Self.normalizedIdentifier(promptRewriteOpenAIModel)
            if normalized != promptRewriteOpenAIModel {
                promptRewriteOpenAIModel = normalized
                return
            }
            if normalized.isEmpty {
                promptRewriteModelByProvider.removeValue(forKey: promptRewriteProviderMode.rawValue)
            } else {
                promptRewriteModelByProvider[promptRewriteProviderMode.rawValue] = normalized
            }
            save()
        }
    }

    @Published var promptRewriteOpenAIBaseURL: String {
        didSet {
            let normalized = Self.normalizedIdentifier(promptRewriteOpenAIBaseURL)
            if normalized != promptRewriteOpenAIBaseURL {
                promptRewriteOpenAIBaseURL = normalized
                return
            }
            if normalized.isEmpty {
                promptRewriteBaseURLByProvider.removeValue(forKey: promptRewriteProviderMode.rawValue)
            } else {
                promptRewriteBaseURLByProvider[promptRewriteProviderMode.rawValue] = normalized
            }
            save()
        }
    }

    @Published var promptRewriteRequestTimeoutSeconds: Double {
        didSet {
            let normalized = min(
                PromptRewriteRequestTimeoutDefaults.maximumSeconds,
                max(PromptRewriteRequestTimeoutDefaults.minimumSeconds, promptRewriteRequestTimeoutSeconds)
            )
            guard normalized == promptRewriteRequestTimeoutSeconds else {
                promptRewriteRequestTimeoutSeconds = normalized
                return
            }
            save()
        }
    }

    @Published var promptRewriteAlwaysConvertToMarkdown: Bool {
        didSet {
            save()
        }
    }

    @Published var promptRewriteStylePresetRawValue: String {
        didSet {
            save()
        }
    }

    @Published var promptRewriteCustomStyleInstructions: String {
        didSet {
            save()
        }
    }

    @Published var promptRewriteConversationHistoryEnabled: Bool {
        didSet {
            save()
        }
    }

    @Published var promptRewriteConversationTimeoutMinutes: Double {
        didSet {
            let normalized = min(240, max(2, promptRewriteConversationTimeoutMinutes))
            guard normalized == promptRewriteConversationTimeoutMinutes else {
                promptRewriteConversationTimeoutMinutes = normalized
                return
            }
            save()
        }
    }

    @Published var promptRewriteConversationTurnLimit: Int {
        didSet {
            let normalized = min(50, max(1, promptRewriteConversationTurnLimit))
            guard normalized == promptRewriteConversationTurnLimit else {
                promptRewriteConversationTurnLimit = normalized
                return
            }
            save()
        }
    }

    @Published var promptRewriteConversationPinnedContextID: String {
        didSet {
            save()
        }
    }

    @Published var promptRewriteConversationHistoryDisabledContextIDs: [String] {
        didSet {
            let normalized = Self.normalizedStringList(promptRewriteConversationHistoryDisabledContextIDs)
            guard normalized == promptRewriteConversationHistoryDisabledContextIDs else {
                promptRewriteConversationHistoryDisabledContextIDs = normalized
                return
            }
            save()
        }
    }

    @Published var promptRewriteCrossIDEConversationSharingEnabled: Bool {
        didSet {
            save()
        }
    }

    @Published var promptRewriteOpenAIAPIKey: String {
        didSet {
            Self.storePromptRewriteProviderAPIKey(
                promptRewriteOpenAIAPIKey,
                for: promptRewriteProviderMode
            )
            if promptRewriteProviderMode == .google,
               googleAIStudioAPIKey != promptRewriteOpenAIAPIKey {
                googleAIStudioAPIKey = promptRewriteOpenAIAPIKey
            }
            save()
        }
    }

    @Published var googleAIStudioAPIKey: String {
        didSet {
            Self.storeGoogleAIStudioAPIKey(googleAIStudioAPIKey)
            if promptRewriteProviderMode == .google,
               promptRewriteOpenAIAPIKey != googleAIStudioAPIKey {
                promptRewriteOpenAIAPIKey = googleAIStudioAPIKey
            }
            if cloudTranscriptionProvider == .gemini,
               cloudTranscriptionAPIKey != googleAIStudioAPIKey {
                cloudTranscriptionAPIKey = googleAIStudioAPIKey
            }
            save()
        }
    }

    @Published var googleAIStudioImageGenerationModel: String {
        didSet {
            let normalized = Self.normalizedIdentifier(googleAIStudioImageGenerationModel)
            if normalized != googleAIStudioImageGenerationModel {
                googleAIStudioImageGenerationModel = normalized
                return
            }
            if normalized.isEmpty {
                googleAIStudioImageGenerationModel = Self.googleAIStudioImageGenerationDefaultModel
                return
            }
            save()
        }
    }

    @Published var localAISetupCompleted: Bool {
        didSet {
            save()
        }
    }

    @Published var localAISelectedModelID: String {
        didSet {
            save()
        }
    }

    @Published var localAIManagedRuntimeEnabled: Bool {
        didSet {
            save()
        }
    }

    @Published var localAIRuntimeVersion: String {
        didSet {
            save()
        }
    }

    @Published var localAILastHealthCheckEpoch: Double {
        didSet {
            save()
        }
    }

    @Published var assistantBetaEnabled: Bool {
        didSet {
            save()
        }
    }

    @Published var assistantVoiceTaskEntryEnabled: Bool {
        didSet {
            save()
        }
    }

    @Published var assistantFloatingHUDEnabled: Bool {
        didSet {
            save()
        }
    }

    @Published var assistantCompactPresentationStyleRawValue: String {
        didSet {
            save()
        }
    }

    @Published var assistantCompactSidebarEdgeRawValue: String {
        didSet {
            save()
        }
    }

    @Published var assistantCompactSidebarPinned: Bool {
        didSet {
            save()
        }
    }

    @Published var assistantNotchHoverDelayRawValue: String {
        didSet {
            save()
        }
    }

    @Published var assistantBetaWarningAcknowledged: Bool {
        didSet {
            save()
        }
    }

    @Published var assistantVoiceOutputEnabled: Bool {
        didSet {
            save()
        }
    }

    @Published var assistantVoiceEngineRawValue: String {
        didSet {
            save()
        }
    }

    @Published var assistantHumeAPIKey: String {
        didSet {
            let trimmed = assistantHumeAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed == assistantHumeAPIKey else {
                assistantHumeAPIKey = trimmed
                return
            }
            Self.storeAssistantHumeCredential(trimmed, account: Self.assistantHumeAPIKeychainAccount)
            save()
        }
    }

    @Published var assistantHumeSecretKey: String {
        didSet {
            let trimmed = assistantHumeSecretKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed == assistantHumeSecretKey else {
                assistantHumeSecretKey = trimmed
                return
            }
            Self.storeAssistantHumeCredential(trimmed, account: Self.assistantHumeSecretKeychainAccount)
            save()
        }
    }

    @Published var assistantHumeVoiceID: String {
        didSet {
            let trimmed = assistantHumeVoiceID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed == assistantHumeVoiceID else {
                assistantHumeVoiceID = trimmed
                return
            }
            if oldValue != assistantHumeVoiceID {
                assistantHumeConversationConfigID = ""
                assistantHumeConversationConfigVersion = 0
            }
            save()
        }
    }

    @Published var assistantHumeVoiceName: String {
        didSet {
            let trimmed = assistantHumeVoiceName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed == assistantHumeVoiceName else {
                assistantHumeVoiceName = trimmed
                return
            }
            save()
        }
    }

    @Published var assistantHumeVoiceSourceRawValue: String {
        didSet {
            let trimmed = assistantHumeVoiceSourceRawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed == assistantHumeVoiceSourceRawValue else {
                assistantHumeVoiceSourceRawValue = trimmed
                return
            }
            if oldValue != assistantHumeVoiceSourceRawValue {
                assistantHumeConversationConfigID = ""
                assistantHumeConversationConfigVersion = 0
            }
            save()
        }
    }

    @Published var assistantHumeConversationConfigID: String {
        didSet {
            let trimmed = assistantHumeConversationConfigID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed == assistantHumeConversationConfigID else {
                assistantHumeConversationConfigID = trimmed
                return
            }
            save()
        }
    }

    @Published var assistantHumeConversationConfigVersion: Int {
        didSet {
            let normalized = max(0, assistantHumeConversationConfigVersion)
            guard normalized == assistantHumeConversationConfigVersion else {
                assistantHumeConversationConfigVersion = normalized
                return
            }
            save()
        }
    }

    @Published var assistantTTSFallbackToMacOS: Bool {
        didSet {
            save()
        }
    }

    @Published var assistantTTSFallbackVoiceIdentifier: String {
        didSet {
            save()
        }
    }

    @Published var assistantInterruptCurrentSpeechOnNewReply: Bool {
        didSet {
            save()
        }
    }

    @Published var assistantBackendRawValue: String {
        didSet {
            let normalized = (
                AssistantRuntimeBackend(rawValue: assistantBackendRawValue) ?? .codex
            ).rawValue
            guard normalized == assistantBackendRawValue else {
                assistantBackendRawValue = normalized
                return
            }
            save()
        }
    }

    var assistantBackend: AssistantRuntimeBackend {
        get { AssistantRuntimeBackend(rawValue: assistantBackendRawValue) ?? .codex }
        set { assistantBackendRawValue = newValue.rawValue }
    }

    @Published var assistantPreferredModelID: String {
        didSet {
            save()
        }
    }

    @Published var assistantPreferredSubagentModelID: String {
        didSet {
            save()
        }
    }

    @Published var assistantOwnedThreadIDs: [String] {
        didSet {
            let normalized = Self.normalizedStringList(assistantOwnedThreadIDs)
            guard normalized == assistantOwnedThreadIDs else {
                assistantOwnedThreadIDs = normalized
                return
            }
            save()
        }
    }

    @Published var assistantArchiveDefaultRetentionHours: Int {
        didSet {
            let normalized = min(24 * 365, max(1, assistantArchiveDefaultRetentionHours))
            guard normalized == assistantArchiveDefaultRetentionHours else {
                assistantArchiveDefaultRetentionHours = normalized
                return
            }
            save()
        }
    }

    @Published var assistantAlwaysApprovedToolKinds: Set<String> {
        didSet {
            save()
        }
    }

    @Published var browserAutomationEnabled: Bool {
        didSet {
            save()
        }
    }

    @Published var assistantComputerUseEnabled: Bool {
        didSet {
            save()
        }
    }

    @Published var browserSelectedProfileID: String {
        didSet {
            save()
        }
    }

    @Published var settingsLastViewedSection: String {
        didSet {
            save()
        }
    }

    @Published var settingsGettingStartedDismissed: Bool {
        didSet {
            save()
        }
    }

    @Published var assistantCustomInstructions: String {
        didSet {
            save()
        }
    }

    /// Maximum number of tool calls allowed per agent turn before auto-cancelling. 0 = unlimited.
    @Published var assistantMaxToolCallsPerTurn: Int {
        didSet {
            save()
        }
    }

    /// Maximum number of times the same command can repeat back-to-back in one turn before auto-cancelling. 0 = unlimited.
    @Published var assistantMaxRepeatedCommandAttemptsPerTurn: Int {
        didSet {
            save()
        }
    }

    @Published var assistantTrackCodeChangesInGitRepos: Bool {
        didSet {
            save()
        }
    }

    @Published var assistantMemoryEnabled: Bool {
        didSet {
            save()
        }
    }

    @Published var assistantMemoryReviewEnabled: Bool {
        didSet {
            save()
        }
    }

    @Published var assistantMemorySummaryMaxChars: Int {
        didSet {
            let clamped = min(max(assistantMemorySummaryMaxChars, 400), 6_000)
            guard clamped == assistantMemorySummaryMaxChars else {
                assistantMemorySummaryMaxChars = clamped
                return
            }
            save()
        }
    }

    @Published var assistantNotesBackupFolderPath: String {
        didSet {
            save()
        }
    }

    @Published var assistantNotesLastSuccessfulBackupEpoch: Double {
        didSet {
            save()
        }
    }

    @Published var availableMicrophones: [MicrophoneOption] = []
    @Published var accessibilityTrusted: Bool = AXIsProcessTrusted()

    /// Called whenever user-facing settings change. The app can subscribe and reconfigure features.
    var onChange: (() -> Void)?

    struct CrossIDEConversationSharingBootstrapState {
        let settingEnabled: Bool
        let runtimeEnabled: Bool
        let source: String
        let migrationApplied: Bool
    }

    static func resolveCrossIDEConversationSharingBootstrap(
        defaults: UserDefaults = .standard,
        featureResolution: FeatureFlags.CrossIDEConversationSharingResolution? = nil
    ) -> CrossIDEConversationSharingBootstrapState {
        let resolvedFeature = featureResolution
            ?? FeatureFlags.crossIDEConversationSharingResolution(defaults: defaults)
        let migrationSentinelKey = Keys.promptRewriteCrossIDEConversationSharingDefaultedMigrationV1
        let sharingDefaultsKey = Keys.promptRewriteCrossIDEConversationSharingEnabled
        let hasMigrationSentinel = defaults.object(forKey: migrationSentinelKey) != nil
        let environmentHardOff = resolvedFeature.source == .env && resolvedFeature.enabled == false

        if !hasMigrationSentinel && !environmentHardOff {
            defaults.set(true, forKey: sharingDefaultsKey)
            defaults.set(true, forKey: migrationSentinelKey)
            return CrossIDEConversationSharingBootstrapState(
                settingEnabled: true,
                runtimeEnabled: true,
                source: "migration",
                migrationApplied: true
            )
        }

        let settingEnabled: Bool
        if defaults.object(forKey: sharingDefaultsKey) == nil {
            settingEnabled = environmentHardOff ? false : true
            if !environmentHardOff {
                defaults.set(settingEnabled, forKey: sharingDefaultsKey)
            }
        } else {
            settingEnabled = defaults.bool(forKey: sharingDefaultsKey)
        }

        let runtimeResolution = featureResolution
            ?? FeatureFlags.crossIDEConversationSharingResolution(defaults: defaults)
        return CrossIDEConversationSharingBootstrapState(
            settingEnabled: settingEnabled,
            runtimeEnabled: runtimeResolution.enabled,
            source: runtimeResolution.source.rawValue,
            migrationApplied: false
        )
    }

    private init() {
        isApplyingChanges = true

        var initialShortcutKeyCode: UInt16
        if defaults.object(forKey: Keys.shortcutKeyCode) == nil {
            initialShortcutKeyCode = ShortcutValidation.defaultKeyCode
        } else {
            initialShortcutKeyCode = UInt16(defaults.integer(forKey: Keys.shortcutKeyCode))
        }

        let storedModifiers = defaults.integer(forKey: Keys.shortcutModifiers)
        var initialShortcutModifiers = storedModifiers == 0
            ? ShortcutValidation.defaultModifiers
            : UInt(storedModifiers)

        if !ShortcutValidation.isValid(keyCode: initialShortcutKeyCode, modifiersRaw: initialShortcutModifiers) {
            initialShortcutKeyCode = ShortcutValidation.defaultKeyCode
            initialShortcutModifiers = ShortcutValidation.defaultModifiers
        }
        shortcutKeyCode = initialShortcutKeyCode
        shortcutModifiers = ShortcutValidation.filteredModifierRawValue(from: initialShortcutModifiers)

        let storedContinuousToggleKeyCode: UInt16
        if defaults.object(forKey: Keys.continuousToggleShortcutKeyCode) == nil {
            storedContinuousToggleKeyCode = ContinuousToggleDefaults.keyCode
        } else {
            storedContinuousToggleKeyCode = UInt16(defaults.integer(forKey: Keys.continuousToggleShortcutKeyCode))
        }

        let storedContinuousToggleModifiersRaw: UInt
        if defaults.object(forKey: Keys.continuousToggleShortcutModifiers) == nil {
            storedContinuousToggleModifiersRaw = ContinuousToggleDefaults.modifiers
        } else {
            storedContinuousToggleModifiersRaw = UInt(defaults.integer(forKey: Keys.continuousToggleShortcutModifiers))
        }

        let resolvedContinuousToggle = Self.resolveContinuousToggleShortcut(
            keyCode: storedContinuousToggleKeyCode,
            modifiersRaw: storedContinuousToggleModifiersRaw,
            holdToTalkKeyCode: initialShortcutKeyCode,
            holdToTalkModifiersRaw: ShortcutValidation.filteredModifierRawValue(from: initialShortcutModifiers)
        )
        continuousToggleShortcutKeyCode = resolvedContinuousToggle.keyCode
        continuousToggleShortcutModifiers = resolvedContinuousToggle.modifiersRaw

        let storedAssistantLiveVoiceShortcutKeyCode: UInt16
        if defaults.object(forKey: Keys.assistantLiveVoiceShortcutKeyCode) == nil {
            storedAssistantLiveVoiceShortcutKeyCode = AssistantLiveVoiceShortcutDefaults.keyCode
        } else {
            storedAssistantLiveVoiceShortcutKeyCode = UInt16(defaults.integer(forKey: Keys.assistantLiveVoiceShortcutKeyCode))
        }

        let storedAssistantLiveVoiceShortcutModifiersRaw: UInt
        if defaults.object(forKey: Keys.assistantLiveVoiceShortcutModifiers) == nil {
            storedAssistantLiveVoiceShortcutModifiersRaw = AssistantLiveVoiceShortcutDefaults.modifiers
        } else {
            storedAssistantLiveVoiceShortcutModifiersRaw = UInt(defaults.integer(forKey: Keys.assistantLiveVoiceShortcutModifiers))
        }

        let resolvedAssistantLiveVoiceShortcut = Self.resolveAssistantLiveVoiceShortcut(
            keyCode: storedAssistantLiveVoiceShortcutKeyCode,
            modifiersRaw: storedAssistantLiveVoiceShortcutModifiersRaw,
            holdToTalkKeyCode: initialShortcutKeyCode,
            holdToTalkModifiersRaw: ShortcutValidation.filteredModifierRawValue(from: initialShortcutModifiers),
            continuousToggleKeyCode: resolvedContinuousToggle.keyCode,
            continuousToggleModifiersRaw: resolvedContinuousToggle.modifiersRaw
        )
        assistantLiveVoiceShortcutKeyCode = resolvedAssistantLiveVoiceShortcut.keyCode
        assistantLiveVoiceShortcutModifiers = resolvedAssistantLiveVoiceShortcut.modifiersRaw

        let storedAssistantCompactShortcutKeyCode: UInt16
        if defaults.object(forKey: Keys.assistantCompactShortcutKeyCode) == nil {
            storedAssistantCompactShortcutKeyCode = AssistantCompactShortcutDefaults.keyCode
        } else {
            storedAssistantCompactShortcutKeyCode = UInt16(defaults.integer(forKey: Keys.assistantCompactShortcutKeyCode))
        }

        let storedAssistantCompactShortcutModifiersRaw: UInt
        if defaults.object(forKey: Keys.assistantCompactShortcutModifiers) == nil {
            storedAssistantCompactShortcutModifiersRaw = AssistantCompactShortcutDefaults.modifiers
        } else {
            storedAssistantCompactShortcutModifiersRaw = UInt(defaults.integer(forKey: Keys.assistantCompactShortcutModifiers))
        }

        let resolvedAssistantCompactShortcut = Self.resolveAssistantCompactShortcut(
            keyCode: storedAssistantCompactShortcutKeyCode,
            modifiersRaw: storedAssistantCompactShortcutModifiersRaw,
            holdToTalkKeyCode: initialShortcutKeyCode,
            holdToTalkModifiersRaw: ShortcutValidation.filteredModifierRawValue(from: initialShortcutModifiers),
            continuousToggleKeyCode: resolvedContinuousToggle.keyCode,
            continuousToggleModifiersRaw: resolvedContinuousToggle.modifiersRaw,
            assistantLiveVoiceKeyCode: resolvedAssistantLiveVoiceShortcut.keyCode,
            assistantLiveVoiceModifiersRaw: resolvedAssistantLiveVoiceShortcut.modifiersRaw
        )
        assistantCompactShortcutKeyCode = resolvedAssistantCompactShortcut.keyCode
        assistantCompactShortcutModifiers = resolvedAssistantCompactShortcut.modifiersRaw

        if defaults.object(forKey: Keys.muteSystemSoundsWhileHoldingShortcut) == nil {
            muteSystemSoundsWhileHoldingShortcut = false
        } else {
            muteSystemSoundsWhileHoldingShortcut = defaults.bool(forKey: Keys.muteSystemSoundsWhileHoldingShortcut)
        }

        if defaults.object(forKey: Keys.autoDetectMicrophone) == nil {
            autoDetectMicrophone = true
        } else {
            autoDetectMicrophone = defaults.bool(forKey: Keys.autoDetectMicrophone)
        }

        if defaults.object(forKey: Keys.copyToClipboard) == nil {
            copyToClipboard = false
        } else {
            copyToClipboard = defaults.bool(forKey: Keys.copyToClipboard)
        }

        if defaults.object(forKey: Keys.insertionDiagnosticsEnabled) == nil {
            insertionDiagnosticsEnabled = false
        } else {
            insertionDiagnosticsEnabled = defaults.bool(forKey: Keys.insertionDiagnosticsEnabled)
        }

        if defaults.object(forKey: Keys.enableContextualBias) == nil {
            enableContextualBias = true
        } else {
            enableContextualBias = defaults.bool(forKey: Keys.enableContextualBias)
        }

        if defaults.object(forKey: Keys.keepTextAcrossPauses) == nil {
            keepTextAcrossPauses = true
        } else {
            keepTextAcrossPauses = defaults.bool(forKey: Keys.keepTextAcrossPauses)
        }

        // Migration: convert legacy preferOnDeviceRecognition bool → recognitionMode
        if let storedMode = defaults.string(forKey: Keys.recognitionMode),
           RecognitionMode(rawValue: storedMode) != nil {
            recognitionModeRawValue = storedMode
        } else if defaults.object(forKey: Keys.preferOnDeviceRecognition) != nil {
            let oldPref = defaults.bool(forKey: Keys.preferOnDeviceRecognition)
            recognitionModeRawValue = (oldPref ? RecognitionMode.localOnly : RecognitionMode.automatic).rawValue
        } else {
            recognitionModeRawValue = RecognitionMode.localOnly.rawValue
        }

        let storedFinalizeDelay = defaults.object(forKey: Keys.finalizeDelaySeconds) == nil
            ? 0.25
            : defaults.double(forKey: Keys.finalizeDelaySeconds)
        finalizeDelaySeconds = min(1.2, max(0.15, storedFinalizeDelay))

        customContextPhrases = defaults.string(forKey: Keys.customContextPhrases) ?? ""

        let storedCleanup = defaults.string(forKey: Keys.textCleanupMode) ?? TextCleanupMode.light.rawValue
        if TextCleanupMode(rawValue: storedCleanup) == nil {
            textCleanupModeRawValue = TextCleanupMode.light.rawValue
        } else {
            textCleanupModeRawValue = storedCleanup
        }

        if defaults.object(forKey: Keys.autoPunctuation) == nil {
            autoPunctuation = true
        } else {
            autoPunctuation = defaults.bool(forKey: Keys.autoPunctuation)
        }

        let storedTheme = defaults.string(forKey: Keys.waveformTheme) ?? WaveformTheme.vibrantSpectrum.rawValue
        if WaveformTheme(rawValue: storedTheme) == nil {
            waveformThemeRawValue = WaveformTheme.vibrantSpectrum.rawValue
        } else {
            waveformThemeRawValue = storedTheme
        }

        let storedChromeStyle = defaults.string(forKey: Keys.appChromeStyle) ?? AppChromeStyle.glassHighContrast.rawValue
        if AppChromeStyle(rawValue: storedChromeStyle) == nil {
            appChromeStyleRawValue = AppChromeStyle.glassHighContrast.rawValue
        } else {
            appChromeStyleRawValue = storedChromeStyle
        }

        let storedColorTheme = defaults.string(forKey: Keys.colorTheme) ?? ColorTheme.ocean.rawValue
        if ColorTheme(rawValue: storedColorTheme) == nil {
            colorThemeRawValue = ColorTheme.ocean.rawValue
        } else {
            colorThemeRawValue = storedColorTheme
        }

        let storedEngine = defaults.string(forKey: Keys.transcriptionEngine) ?? TranscriptionEngineType.appleSpeech.rawValue
        if TranscriptionEngineType(rawValue: storedEngine) == nil {
            transcriptionEngineRawValue = TranscriptionEngineType.appleSpeech.rawValue
        } else {
            transcriptionEngineRawValue = storedEngine
        }

        let storedCloudProviderRawValue = defaults.string(forKey: Keys.cloudTranscriptionProvider)
            ?? CloudTranscriptionProvider.openAI.rawValue
        let resolvedCloudProviderRawValue: String
        if CloudTranscriptionProvider(rawValue: storedCloudProviderRawValue) == nil {
            resolvedCloudProviderRawValue = CloudTranscriptionProvider.openAI.rawValue
        } else {
            resolvedCloudProviderRawValue = storedCloudProviderRawValue
        }
        cloudTranscriptionProviderRawValue = resolvedCloudProviderRawValue
        let selectedCloudProvider = CloudTranscriptionProvider(rawValue: resolvedCloudProviderRawValue) ?? .openAI
        let sanitizedCloudConfiguration = Self.sanitizedCloudTranscriptionConfiguration(
            provider: selectedCloudProvider,
            model: defaults.string(forKey: Keys.cloudTranscriptionModel) ?? selectedCloudProvider.defaultModel,
            baseURL: defaults.string(forKey: Keys.cloudTranscriptionBaseURL) ?? selectedCloudProvider.defaultBaseURL
        )
        cloudTranscriptionModel = sanitizedCloudConfiguration.model
        cloudTranscriptionBaseURL = sanitizedCloudConfiguration.baseURL
        let storedCloudRequestTimeoutSeconds = defaults.object(forKey: Keys.cloudTranscriptionRequestTimeoutSeconds) == nil
            ? CloudTranscriptionRequestTimeoutDefaults.fallbackSeconds
            : defaults.double(forKey: Keys.cloudTranscriptionRequestTimeoutSeconds)
        cloudTranscriptionRequestTimeoutSeconds = min(
            CloudTranscriptionRequestTimeoutDefaults.maximumSeconds,
            max(CloudTranscriptionRequestTimeoutDefaults.minimumSeconds, storedCloudRequestTimeoutSeconds)
        )
        googleAIStudioAPIKey = Self.loadGoogleAIStudioAPIKey()
        cloudTranscriptionAPIKey = Self.loadCloudTranscriptionProviderAPIKey(for: selectedCloudProvider)

        selectedWhisperModelID = defaults.string(forKey: Keys.selectedWhisperModelID) ?? ""

        if defaults.object(forKey: Keys.whisperUseCoreML) == nil {
            whisperUseCoreML = true
        } else {
            whisperUseCoreML = defaults.bool(forKey: Keys.whisperUseCoreML)
        }

        if defaults.object(forKey: Keys.whisperAutoUnloadIdleContextEnabled) == nil {
            whisperAutoUnloadIdleContextEnabled = true
        } else {
            whisperAutoUnloadIdleContextEnabled = defaults.bool(forKey: Keys.whisperAutoUnloadIdleContextEnabled)
        }

        let storedWhisperContextUnloadDelaySeconds = defaults.object(forKey: Keys.whisperIdleContextUnloadSeconds) == nil
            ? WhisperContextRetentionDefaults.fallbackSeconds
            : defaults.double(forKey: Keys.whisperIdleContextUnloadSeconds)
        whisperIdleContextUnloadSeconds = min(
            WhisperContextRetentionDefaults.maximumSeconds,
            max(WhisperContextRetentionDefaults.minimumSeconds, storedWhisperContextUnloadDelaySeconds)
        )

        if defaults.object(forKey: Keys.adaptiveCorrectionsEnabled) == nil {
            adaptiveCorrectionsEnabled = true
        } else {
            adaptiveCorrectionsEnabled = defaults.bool(forKey: Keys.adaptiveCorrectionsEnabled)
        }

        if defaults.object(forKey: Keys.playCorrectionLearnedSound) == nil {
            playCorrectionLearnedSound = true
        } else {
            playCorrectionLearnedSound = defaults.bool(forKey: Keys.playCorrectionLearnedSound)
        }

        let storedStartSoundName = defaults.string(forKey: Keys.dictationStartSoundName)
            ?? Self.defaultDictationStartSoundName
        dictationStartSoundName = Self.dictationStartSoundOptions.contains(storedStartSoundName)
            ? storedStartSoundName
            : Self.defaultDictationStartSoundName
        let storedStopSoundName = defaults.string(forKey: Keys.dictationStopSoundName)
            ?? Self.defaultDictationStopSoundName
        dictationStopSoundName = Self.dictationStartSoundOptions.contains(storedStopSoundName)
            ? storedStopSoundName
            : Self.defaultDictationStopSoundName
        let storedProcessingSoundName = defaults.string(forKey: Keys.dictationProcessingSoundName)
            ?? Self.defaultDictationProcessingSoundName
        dictationProcessingSoundName = Self.dictationStartSoundOptions.contains(storedProcessingSoundName)
            ? storedProcessingSoundName
            : Self.defaultDictationProcessingSoundName
        let storedPastedSoundName = defaults.string(forKey: Keys.dictationPastedSoundName)
            ?? Self.defaultDictationPastedSoundName
        dictationPastedSoundName = Self.dictationStartSoundOptions.contains(storedPastedSoundName)
            ? storedPastedSoundName
            : Self.defaultDictationPastedSoundName
        let storedCorrectionSoundName = defaults.string(forKey: Keys.dictationCorrectionLearnedSoundName)
            ?? Self.defaultDictationCorrectionLearnedSoundName
        dictationCorrectionLearnedSoundName = Self.dictationStartSoundOptions.contains(storedCorrectionSoundName)
            ? storedCorrectionSoundName
            : Self.defaultDictationCorrectionLearnedSoundName
        dictationFeedbackVolume = defaults.object(forKey: Keys.dictationFeedbackVolume) == nil
            ? Self.defaultDictationFeedbackVolume
            : min(1, max(0, defaults.double(forKey: Keys.dictationFeedbackVolume)))

        if defaults.object(forKey: Keys.automationAPIEnabled) == nil {
            automationAPIEnabled = false
        } else {
            automationAPIEnabled = defaults.bool(forKey: Keys.automationAPIEnabled)
        }
        let storedAutomationPort = defaults.object(forKey: Keys.automationAPIPort) == nil
            ? Int(Self.defaultAutomationAPIPort)
            : defaults.integer(forKey: Keys.automationAPIPort)
        automationAPIPort = UInt16(min(Int(UInt16.max), max(1024, storedAutomationPort)))

        if defaults.object(forKey: Keys.automationAPINotificationsEnabled) == nil {
            automationAPINotificationsEnabled = true
        } else {
            automationAPINotificationsEnabled = defaults.bool(forKey: Keys.automationAPINotificationsEnabled)
        }

        if defaults.object(forKey: Keys.automationAPISpeechEnabled) == nil {
            automationAPISpeechEnabled = false
        } else {
            automationAPISpeechEnabled = defaults.bool(forKey: Keys.automationAPISpeechEnabled)
        }

        if defaults.object(forKey: Keys.automationAPISoundEnabled) == nil {
            automationAPISoundEnabled = false
        } else {
            automationAPISoundEnabled = defaults.bool(forKey: Keys.automationAPISoundEnabled)
        }

        automationAPIDefaultVoiceIdentifier = defaults.string(forKey: Keys.automationAPIDefaultVoiceIdentifier)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let storedAutomationSound = defaults.string(forKey: Keys.automationAPIDefaultSound)
            ?? AutomationAPISound.processing.rawValue
        automationAPIDefaultSoundRawValue = AutomationAPISound(rawValue: storedAutomationSound) == nil
            ? AutomationAPISound.processing.rawValue
            : storedAutomationSound

        if defaults.object(forKey: Keys.automationClaudeEnabled) == nil {
            automationClaudeEnabled = true
        } else {
            automationClaudeEnabled = defaults.bool(forKey: Keys.automationClaudeEnabled)
        }

        if defaults.object(forKey: Keys.automationCodexCLIEnabled) == nil {
            automationCodexCLIEnabled = false
        } else {
            automationCodexCLIEnabled = defaults.bool(forKey: Keys.automationCodexCLIEnabled)
        }

        if defaults.object(forKey: Keys.automationCodexCloudEnabled) == nil {
            automationCodexCloudEnabled = false
        } else {
            automationCodexCloudEnabled = defaults.bool(forKey: Keys.automationCodexCloudEnabled)
        }

        if defaults.object(forKey: Keys.telegramRemoteEnabled) == nil {
            telegramRemoteEnabled = false
        } else {
            telegramRemoteEnabled = defaults.bool(forKey: Keys.telegramRemoteEnabled)
        }
        telegramOwnerUserID = defaults.string(forKey: Keys.telegramOwnerUserID)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        telegramOwnerChatID = defaults.string(forKey: Keys.telegramOwnerChatID)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        telegramPendingUserID = defaults.string(forKey: Keys.telegramPendingUserID)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        telegramPendingChatID = defaults.string(forKey: Keys.telegramPendingChatID)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        telegramPendingDisplayName = defaults.string(forKey: Keys.telegramPendingDisplayName) ?? ""

        if defaults.object(forKey: Keys.promptRewriteEnabled) == nil {
            promptRewriteEnabled = true
        } else {
            promptRewriteEnabled = defaults.bool(forKey: Keys.promptRewriteEnabled)
        }

        if defaults.object(forKey: Keys.promptRewriteAutoInsertEnabled) == nil {
            promptRewriteAutoInsertEnabled = false
        } else {
            promptRewriteAutoInsertEnabled = defaults.bool(forKey: Keys.promptRewriteAutoInsertEnabled)
        }

        if defaults.object(forKey: Keys.memoryIndexingEnabled) == nil {
            memoryIndexingEnabled = false
        } else {
            memoryIndexingEnabled = defaults.bool(forKey: Keys.memoryIndexingEnabled)
        }

        if defaults.object(forKey: Keys.memoryProviderCatalogAutoUpdate) == nil {
            memoryProviderCatalogAutoUpdate = true
        } else {
            memoryProviderCatalogAutoUpdate = defaults.bool(forKey: Keys.memoryProviderCatalogAutoUpdate)
        }

        let initialDetectedProviderIDs = Self.normalizedStringList(
            defaults.stringArray(forKey: Keys.memoryDetectedProviderIDs) ?? []
        )
        memoryDetectedProviderIDs = initialDetectedProviderIDs
        if let storedEnabledProviderIDs = defaults.stringArray(forKey: Keys.memoryEnabledProviderIDs) {
            memoryEnabledProviderIDs = Self.normalizedStringList(storedEnabledProviderIDs)
        } else {
            memoryEnabledProviderIDs = []
        }

        let initialDetectedSourceFolderIDs = Self.normalizedStringList(
            defaults.stringArray(forKey: Keys.memoryDetectedSourceFolderIDs) ?? []
        )
        memoryDetectedSourceFolderIDs = initialDetectedSourceFolderIDs
        if let storedEnabledSourceFolderIDs = defaults.stringArray(forKey: Keys.memoryEnabledSourceFolderIDs) {
            memoryEnabledSourceFolderIDs = Self.normalizedStringList(storedEnabledSourceFolderIDs)
        } else {
            memoryEnabledSourceFolderIDs = []
        }

        let storedPromptRewriteProviderMode = defaults.string(forKey: Keys.promptRewriteProviderMode)
            ?? PromptRewriteProviderMode.openAI.rawValue
        let resolvedPromptRewriteProviderModeRaw: String
        if PromptRewriteProviderMode(rawValue: storedPromptRewriteProviderMode) == nil {
            resolvedPromptRewriteProviderModeRaw = PromptRewriteProviderMode.openAI.rawValue
        } else {
            resolvedPromptRewriteProviderModeRaw = storedPromptRewriteProviderMode
        }
        promptRewriteProviderModeRawValue = resolvedPromptRewriteProviderModeRaw
        let selectedPromptProvider = PromptRewriteProviderMode(rawValue: resolvedPromptRewriteProviderModeRaw) ?? .openAI
        let selectedPromptProviderAPIKey = Self.loadPromptRewriteProviderAPIKey(for: selectedPromptProvider)
        let selectedPromptProviderHasOAuthSession = selectedPromptProvider.supportsOAuthSignIn
            && PromptRewriteOAuthCredentialStore.loadSession(for: selectedPromptProvider) != nil

        var modelByProvider = Self.normalizedProviderScopedStringDictionary(
            defaults.dictionary(forKey: Keys.promptRewriteModelByProvider)
        )
        var baseURLByProvider = Self.normalizedProviderScopedStringDictionary(
            defaults.dictionary(forKey: Keys.promptRewriteBaseURLByProvider)
        )

        // One-time migration path for pre-provider-scoped settings:
        // only consult legacy global keys when there is no scoped entry yet
        // and no scoped map exists for that field.
        let shouldMigrateLegacyModel = modelByProvider[selectedPromptProvider.rawValue] == nil
            && modelByProvider.isEmpty
        let storedOpenAIModel = defaults.string(forKey: Keys.promptRewriteOpenAIModel)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if shouldMigrateLegacyModel,
           let storedOpenAIModel,
           !storedOpenAIModel.isEmpty {
            modelByProvider[selectedPromptProvider.rawValue] = storedOpenAIModel
        }
        let selectedProviderModel = modelByProvider[selectedPromptProvider.rawValue] ?? selectedPromptProvider.defaultModel

        let shouldMigrateLegacyBaseURL = baseURLByProvider[selectedPromptProvider.rawValue] == nil
            && baseURLByProvider.isEmpty
        let storedOpenAIBaseURL = defaults.string(forKey: Keys.promptRewriteOpenAIBaseURL)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if shouldMigrateLegacyBaseURL,
           let storedOpenAIBaseURL,
           !storedOpenAIBaseURL.isEmpty {
            baseURLByProvider[selectedPromptProvider.rawValue] = storedOpenAIBaseURL
        }
        let selectedProviderBaseURL = baseURLByProvider[selectedPromptProvider.rawValue] ?? selectedPromptProvider.defaultBaseURL
        let sanitizedPromptProviderConfiguration = Self.sanitizedPromptRewriteProviderConfiguration(
            mode: selectedPromptProvider,
            model: selectedProviderModel,
            baseURL: selectedProviderBaseURL,
            hasOAuthSession: selectedPromptProviderHasOAuthSession,
            hasAPIKey: !selectedPromptProviderAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
        modelByProvider[selectedPromptProvider.rawValue] = sanitizedPromptProviderConfiguration.model
        baseURLByProvider[selectedPromptProvider.rawValue] = sanitizedPromptProviderConfiguration.baseURL
        promptRewriteOpenAIModel = sanitizedPromptProviderConfiguration.model
        promptRewriteOpenAIBaseURL = sanitizedPromptProviderConfiguration.baseURL
        promptRewriteModelByProvider = modelByProvider
        promptRewriteBaseURLByProvider = baseURLByProvider

        if defaults.object(forKey: Keys.promptRewriteAlwaysConvertToMarkdown) == nil {
            promptRewriteAlwaysConvertToMarkdown = false
        } else {
            promptRewriteAlwaysConvertToMarkdown = defaults.bool(forKey: Keys.promptRewriteAlwaysConvertToMarkdown)
        }

        let storedPromptRewriteRequestTimeout = defaults.object(forKey: Keys.promptRewriteRequestTimeoutSeconds) == nil
            ? PromptRewriteRequestTimeoutDefaults.fallbackSeconds
            : defaults.double(forKey: Keys.promptRewriteRequestTimeoutSeconds)
        promptRewriteRequestTimeoutSeconds = min(
            PromptRewriteRequestTimeoutDefaults.maximumSeconds,
            max(PromptRewriteRequestTimeoutDefaults.minimumSeconds, storedPromptRewriteRequestTimeout)
        )

        let storedStylePreset = defaults.string(forKey: Keys.promptRewriteStylePreset)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let storedStylePreset,
           let resolvedStylePreset = PromptRewriteStylePreset(rawValue: storedStylePreset) {
            promptRewriteStylePresetRawValue = resolvedStylePreset.rawValue
        } else {
            promptRewriteStylePresetRawValue = PromptRewriteStylePreset.balanced.rawValue
        }

        promptRewriteCustomStyleInstructions = defaults.string(forKey: Keys.promptRewriteCustomStyleInstructions)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if defaults.object(forKey: Keys.promptRewriteConversationHistoryEnabled) == nil {
            promptRewriteConversationHistoryEnabled = false
        } else {
            promptRewriteConversationHistoryEnabled = defaults.bool(forKey: Keys.promptRewriteConversationHistoryEnabled)
        }

        let storedConversationTimeout = defaults.object(forKey: Keys.promptRewriteConversationTimeoutMinutes) == nil
            ? 25.0
            : defaults.double(forKey: Keys.promptRewriteConversationTimeoutMinutes)
        promptRewriteConversationTimeoutMinutes = min(240, max(2, storedConversationTimeout))

        let storedConversationTurnLimit = defaults.object(forKey: Keys.promptRewriteConversationTurnLimit) == nil
            ? 25
            : defaults.integer(forKey: Keys.promptRewriteConversationTurnLimit)
        promptRewriteConversationTurnLimit = min(50, max(1, storedConversationTurnLimit))

        promptRewriteConversationPinnedContextID = defaults
            .string(forKey: Keys.promptRewriteConversationPinnedContextID)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        promptRewriteConversationHistoryDisabledContextIDs = Self.normalizedStringList(
            defaults.stringArray(forKey: Keys.promptRewriteConversationHistoryDisabledContextIDs) ?? []
        )

        let crossIDEBootstrap = Self.resolveCrossIDEConversationSharingBootstrap(defaults: defaults)
        promptRewriteCrossIDEConversationSharingEnabled = crossIDEBootstrap.settingEnabled
        CrashReporter.logInfo(
            "Cross-IDE conversation sharing resolved source=\(crossIDEBootstrap.source) " +
            "runtimeEnabled=\(crossIDEBootstrap.runtimeEnabled) " +
            "settingEnabled=\(crossIDEBootstrap.settingEnabled) " +
            "migrationApplied=\(crossIDEBootstrap.migrationApplied)"
        )

        promptRewriteOpenAIAPIKey = selectedPromptProviderAPIKey
        googleAIStudioImageGenerationModel = defaults
            .string(forKey: Keys.googleAIStudioImageGenerationModel)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? Self.googleAIStudioImageGenerationDefaultModel

        if defaults.object(forKey: Keys.localAISetupCompleted) == nil {
            localAISetupCompleted = false
        } else {
            localAISetupCompleted = defaults.bool(forKey: Keys.localAISetupCompleted)
        }

        localAISelectedModelID = defaults
            .string(forKey: Keys.localAISelectedModelID)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if defaults.object(forKey: Keys.localAIManagedRuntimeEnabled) == nil {
            localAIManagedRuntimeEnabled = true
        } else {
            localAIManagedRuntimeEnabled = defaults.bool(forKey: Keys.localAIManagedRuntimeEnabled)
        }

        localAIRuntimeVersion = defaults
            .string(forKey: Keys.localAIRuntimeVersion)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        localAILastHealthCheckEpoch = defaults.object(forKey: Keys.localAILastHealthCheckEpoch) == nil
            ? 0
            : defaults.double(forKey: Keys.localAILastHealthCheckEpoch)

        if defaults.object(forKey: Keys.assistantBetaEnabled) == nil {
            assistantBetaEnabled = false
        } else {
            assistantBetaEnabled = defaults.bool(forKey: Keys.assistantBetaEnabled)
        }

        if defaults.object(forKey: Keys.assistantVoiceTaskEntryEnabled) == nil {
            assistantVoiceTaskEntryEnabled = true
        } else {
            assistantVoiceTaskEntryEnabled = defaults.bool(forKey: Keys.assistantVoiceTaskEntryEnabled)
        }

        if defaults.object(forKey: Keys.assistantFloatingHUDEnabled) == nil {
            assistantFloatingHUDEnabled = true
        } else {
            assistantFloatingHUDEnabled = defaults.bool(forKey: Keys.assistantFloatingHUDEnabled)
        }

        assistantCompactPresentationStyleRawValue = Self.restoredAssistantCompactPresentationStyle(
            defaults: defaults
        ).rawValue

        assistantCompactSidebarEdgeRawValue = Self.restoredAssistantCompactSidebarEdge(
            defaults: defaults
        ).rawValue

        assistantCompactSidebarPinned = Self.restoredAssistantCompactSidebarPinned(
            defaults: defaults
        )

        assistantNotchHoverDelayRawValue = (
            AssistantNotchHoverDelay(
                rawValue: defaults.string(forKey: Keys.assistantNotchHoverDelay) ?? ""
            ) ?? .twoSeconds
        ).rawValue

        if defaults.object(forKey: Keys.assistantBetaWarningAcknowledged) == nil {
            assistantBetaWarningAcknowledged = false
        } else {
            assistantBetaWarningAcknowledged = defaults.bool(forKey: Keys.assistantBetaWarningAcknowledged)
        }

        if defaults.object(forKey: Keys.assistantVoiceOutputEnabled) == nil {
            assistantVoiceOutputEnabled = false
        } else {
            assistantVoiceOutputEnabled = defaults.bool(forKey: Keys.assistantVoiceOutputEnabled)
        }

        let storedAssistantVoiceEngineRawValue = defaults.string(forKey: Keys.assistantVoiceEngine)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch storedAssistantVoiceEngineRawValue {
        case AssistantSpeechEngine.macos.rawValue:
            assistantVoiceEngineRawValue = AssistantSpeechEngine.macos.rawValue
        case "tada":
            assistantVoiceEngineRawValue = AssistantSpeechEngine.humeOctave.rawValue
        default:
            assistantVoiceEngineRawValue = (
                AssistantSpeechEngine(rawValue: storedAssistantVoiceEngineRawValue ?? "")?.rawValue
                    ?? AssistantSpeechEngine.humeOctave.rawValue
            )
        }

        assistantHumeAPIKey = Self.loadAssistantHumeCredential(account: Self.assistantHumeAPIKeychainAccount)
        assistantHumeSecretKey = Self.loadAssistantHumeCredential(account: Self.assistantHumeSecretKeychainAccount)
        assistantHumeVoiceID = defaults.string(forKey: Keys.assistantHumeVoiceID)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        assistantHumeVoiceName = defaults.string(forKey: Keys.assistantHumeVoiceName)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let storedAssistantHumeVoiceSource = defaults.string(forKey: Keys.assistantHumeVoiceSource)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        assistantHumeVoiceSourceRawValue =
            AssistantHumeVoiceSource(rawValue: storedAssistantHumeVoiceSource ?? "")?.rawValue
            ?? AssistantHumeVoiceSource.humeAI.rawValue
        assistantHumeConversationConfigID = defaults.string(forKey: Keys.assistantHumeConversationConfigID)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if defaults.object(forKey: Keys.assistantHumeConversationConfigVersion) == nil {
            assistantHumeConversationConfigVersion = 0
        } else {
            assistantHumeConversationConfigVersion = defaults.integer(forKey: Keys.assistantHumeConversationConfigVersion)
        }

        if defaults.object(forKey: Keys.assistantTTSFallbackToMacOS) == nil {
            assistantTTSFallbackToMacOS = true
        } else {
            assistantTTSFallbackToMacOS = defaults.bool(forKey: Keys.assistantTTSFallbackToMacOS)
        }

        assistantTTSFallbackVoiceIdentifier = defaults.string(forKey: Keys.assistantTTSFallbackVoiceIdentifier)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if defaults.object(forKey: Keys.assistantInterruptCurrentSpeechOnNewReply) == nil {
            assistantInterruptCurrentSpeechOnNewReply = true
        } else {
            assistantInterruptCurrentSpeechOnNewReply = defaults.bool(forKey: Keys.assistantInterruptCurrentSpeechOnNewReply)
        }

        assistantBackendRawValue = (
            AssistantRuntimeBackend(
                rawValue: defaults.string(forKey: Keys.assistantBackend) ?? ""
            ) ?? .codex
        ).rawValue
        assistantPreferredModelID = defaults
            .string(forKey: Keys.assistantPreferredModelID)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        assistantPreferredSubagentModelID = defaults
            .string(forKey: Keys.assistantPreferredSubagentModelID)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        assistantOwnedThreadIDs = Self.normalizedStringList(
            defaults.stringArray(forKey: Keys.assistantOwnedThreadIDs) ?? []
        )
        assistantArchiveDefaultRetentionHours = min(
            24 * 365,
            max(
                1,
                Self.restoredInteger(
                    defaults: defaults,
                    key: Keys.assistantArchiveDefaultRetentionHours,
                    defaultValue: 24
                )
            )
        )
        assistantAlwaysApprovedToolKinds = Set(
            defaults.stringArray(forKey: Keys.assistantAlwaysApprovedToolKinds) ?? []
        )
        if defaults.object(forKey: Keys.browserAutomationEnabled) == nil {
            browserAutomationEnabled = false
        } else {
            browserAutomationEnabled = defaults.bool(forKey: Keys.browserAutomationEnabled)
        }
        if defaults.object(forKey: Keys.assistantComputerUseEnabled) == nil {
            assistantComputerUseEnabled = false
        } else {
            assistantComputerUseEnabled = defaults.bool(forKey: Keys.assistantComputerUseEnabled)
        }
        browserSelectedProfileID = defaults.string(forKey: Keys.browserSelectedProfileID)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        settingsLastViewedSection = defaults.string(forKey: Keys.settingsLastViewedSection)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if defaults.object(forKey: Keys.settingsGettingStartedDismissed) == nil {
            settingsGettingStartedDismissed = false
        } else {
            settingsGettingStartedDismissed = defaults.bool(forKey: Keys.settingsGettingStartedDismissed)
        }
        assistantCustomInstructions = defaults.string(forKey: Keys.assistantCustomInstructions) ?? ""
        assistantMaxToolCallsPerTurn = Self.restoredInteger(
            defaults: defaults,
            key: Keys.assistantMaxToolCallsPerTurn,
            defaultValue: 75
        )
        assistantMaxRepeatedCommandAttemptsPerTurn = Self.restoredInteger(
            defaults: defaults,
            key: Keys.assistantMaxRepeatedCommandAttemptsPerTurn,
            defaultValue: 3
        )
        if defaults.object(forKey: Keys.assistantTrackCodeChangesInGitRepos) == nil {
            assistantTrackCodeChangesInGitRepos = true
        } else {
            assistantTrackCodeChangesInGitRepos = defaults.bool(forKey: Keys.assistantTrackCodeChangesInGitRepos)
        }
        if defaults.object(forKey: Keys.assistantMemoryEnabled) == nil {
            assistantMemoryEnabled = true
        } else {
            assistantMemoryEnabled = defaults.bool(forKey: Keys.assistantMemoryEnabled)
        }
        if defaults.object(forKey: Keys.assistantMemoryReviewEnabled) == nil {
            assistantMemoryReviewEnabled = true
        } else {
            assistantMemoryReviewEnabled = defaults.bool(forKey: Keys.assistantMemoryReviewEnabled)
        }
        let storedMemorySummaryMaxChars = defaults.integer(forKey: Keys.assistantMemorySummaryMaxChars)
        assistantMemorySummaryMaxChars = storedMemorySummaryMaxChars > 0
            ? min(max(storedMemorySummaryMaxChars, 400), 6_000)
            : 1_800
        assistantNotesBackupFolderPath = defaults.string(forKey: Keys.assistantNotesBackupFolderPath)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        assistantNotesLastSuccessfulBackupEpoch = defaults.object(forKey: Keys.assistantNotesLastSuccessfulBackupEpoch) == nil
            ? 0
            : defaults.double(forKey: Keys.assistantNotesLastSuccessfulBackupEpoch)

        selectedMicrophoneUID = defaults.string(forKey: Keys.selectedMicrophoneUID) ?? ""

        refreshMicrophones(notifyChange: false)
        refreshAccessibilityStatus(prompt: false)

        isApplyingChanges = false
        save()
    }

    func refreshAccessibilityStatus(prompt: Bool) {
        let previousTrust = accessibilityTrusted

        if prompt {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }

        accessibilityTrusted = AXIsProcessTrusted()
        if !previousTrust && accessibilityTrusted {
            NotificationCenter.default.post(
                name: Self.accessibilityTrustDidBecomeGrantedNotification,
                object: self
            )
        }
    }

    func refreshMicrophones(notifyChange: Bool = true) {
        isApplyingChanges = true
        let previousSelectedMicrophoneUID = selectedMicrophoneUID

        let list = MicrophoneManager.availableMicrophones()
        availableMicrophones = list

        if !autoDetectMicrophone {
            if selectedMicrophoneUID.isEmpty, let fallback = MicrophoneManager.defaultMicrophoneUID() {
                selectedMicrophoneUID = fallback
            }

            if !selectedMicrophoneUID.isEmpty,
               !availableMicrophones.contains(where: { $0.uid == selectedMicrophoneUID }) {
                selectedMicrophoneUID = availableMicrophones.first?.uid ?? ""
            }
        }

        let didChangeSelectedMicrophone = selectedMicrophoneUID != previousSelectedMicrophoneUID
        let shouldNotify = notifyChange && didChangeSelectedMicrophone && onChange != nil
        isApplyingChanges = false
        if shouldNotify {
            onChange?()
        }
    }

    func save() {
        guard saveSuppressionDepth == 0 else { return }
        defaults.set(Int(shortcutKeyCode), forKey: Keys.shortcutKeyCode)
        defaults.set(Int(ShortcutValidation.filteredModifierRawValue(from: shortcutModifiers)), forKey: Keys.shortcutModifiers)
        defaults.set(Int(continuousToggleShortcutKeyCode), forKey: Keys.continuousToggleShortcutKeyCode)
        defaults.set(Int(ShortcutValidation.filteredModifierRawValue(from: continuousToggleShortcutModifiers)), forKey: Keys.continuousToggleShortcutModifiers)
        defaults.set(Int(assistantLiveVoiceShortcutKeyCode), forKey: Keys.assistantLiveVoiceShortcutKeyCode)
        defaults.set(Int(ShortcutValidation.filteredModifierRawValue(from: assistantLiveVoiceShortcutModifiers)), forKey: Keys.assistantLiveVoiceShortcutModifiers)
        defaults.set(Int(assistantCompactShortcutKeyCode), forKey: Keys.assistantCompactShortcutKeyCode)
        defaults.set(Int(ShortcutValidation.filteredModifierRawValue(from: assistantCompactShortcutModifiers)), forKey: Keys.assistantCompactShortcutModifiers)
        defaults.set(muteSystemSoundsWhileHoldingShortcut, forKey: Keys.muteSystemSoundsWhileHoldingShortcut)
        defaults.set(autoDetectMicrophone, forKey: Keys.autoDetectMicrophone)
        defaults.set(selectedMicrophoneUID, forKey: Keys.selectedMicrophoneUID)
        defaults.set(copyToClipboard, forKey: Keys.copyToClipboard)
        defaults.set(insertionDiagnosticsEnabled, forKey: Keys.insertionDiagnosticsEnabled)
        defaults.set(enableContextualBias, forKey: Keys.enableContextualBias)
        defaults.set(keepTextAcrossPauses, forKey: Keys.keepTextAcrossPauses)
        defaults.set(recognitionModeRawValue, forKey: Keys.recognitionMode)
        defaults.set(min(1.2, max(0.15, finalizeDelaySeconds)), forKey: Keys.finalizeDelaySeconds)
        defaults.set(customContextPhrases, forKey: Keys.customContextPhrases)
        defaults.set(textCleanupModeRawValue, forKey: Keys.textCleanupMode)
        defaults.set(autoPunctuation, forKey: Keys.autoPunctuation)
        defaults.set(waveformThemeRawValue, forKey: Keys.waveformTheme)
        defaults.set(appChromeStyleRawValue, forKey: Keys.appChromeStyle)
        defaults.set(colorThemeRawValue, forKey: Keys.colorTheme)
        defaults.set(transcriptionEngineRawValue, forKey: Keys.transcriptionEngine)
        defaults.set(cloudTranscriptionProviderRawValue, forKey: Keys.cloudTranscriptionProvider)
        defaults.set(cloudTranscriptionModel.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.cloudTranscriptionModel)
        defaults.set(cloudTranscriptionBaseURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.cloudTranscriptionBaseURL)
        defaults.set(cloudTranscriptionRequestTimeoutSeconds, forKey: Keys.cloudTranscriptionRequestTimeoutSeconds)
        defaults.set(selectedWhisperModelID, forKey: Keys.selectedWhisperModelID)
        defaults.set(whisperUseCoreML, forKey: Keys.whisperUseCoreML)
        defaults.set(whisperAutoUnloadIdleContextEnabled, forKey: Keys.whisperAutoUnloadIdleContextEnabled)
        defaults.set(whisperIdleContextUnloadSeconds, forKey: Keys.whisperIdleContextUnloadSeconds)
        defaults.set(adaptiveCorrectionsEnabled, forKey: Keys.adaptiveCorrectionsEnabled)
        defaults.set(playCorrectionLearnedSound, forKey: Keys.playCorrectionLearnedSound)
        defaults.set(dictationStartSoundName, forKey: Keys.dictationStartSoundName)
        defaults.set(dictationStopSoundName, forKey: Keys.dictationStopSoundName)
        defaults.set(dictationProcessingSoundName, forKey: Keys.dictationProcessingSoundName)
        defaults.set(dictationPastedSoundName, forKey: Keys.dictationPastedSoundName)
        defaults.set(dictationCorrectionLearnedSoundName, forKey: Keys.dictationCorrectionLearnedSoundName)
        defaults.set(dictationFeedbackVolume, forKey: Keys.dictationFeedbackVolume)
        defaults.set(automationAPIEnabled, forKey: Keys.automationAPIEnabled)
        defaults.set(Int(automationAPIPort), forKey: Keys.automationAPIPort)
        defaults.set(automationAPINotificationsEnabled, forKey: Keys.automationAPINotificationsEnabled)
        defaults.set(automationAPISpeechEnabled, forKey: Keys.automationAPISpeechEnabled)
        defaults.set(automationAPISoundEnabled, forKey: Keys.automationAPISoundEnabled)
        defaults.set(automationAPIDefaultVoiceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.automationAPIDefaultVoiceIdentifier)
        defaults.set(automationAPIDefaultSoundRawValue, forKey: Keys.automationAPIDefaultSound)
        defaults.set(automationClaudeEnabled, forKey: Keys.automationClaudeEnabled)
        defaults.set(automationCodexCLIEnabled, forKey: Keys.automationCodexCLIEnabled)
        defaults.set(automationCodexCloudEnabled, forKey: Keys.automationCodexCloudEnabled)
        defaults.set(telegramRemoteEnabled, forKey: Keys.telegramRemoteEnabled)
        defaults.set(telegramOwnerUserID.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.telegramOwnerUserID)
        defaults.set(telegramOwnerChatID.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.telegramOwnerChatID)
        defaults.set(telegramPendingUserID.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.telegramPendingUserID)
        defaults.set(telegramPendingChatID.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.telegramPendingChatID)
        defaults.set(telegramPendingDisplayName.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.telegramPendingDisplayName)
        defaults.set(promptRewriteEnabled, forKey: Keys.promptRewriteEnabled)
        defaults.set(promptRewriteAutoInsertEnabled, forKey: Keys.promptRewriteAutoInsertEnabled)
        defaults.set(memoryIndexingEnabled, forKey: Keys.memoryIndexingEnabled)
        defaults.set(memoryProviderCatalogAutoUpdate, forKey: Keys.memoryProviderCatalogAutoUpdate)
        defaults.set(Self.normalizedStringList(memoryDetectedProviderIDs), forKey: Keys.memoryDetectedProviderIDs)
        defaults.set(Self.normalizedStringList(memoryEnabledProviderIDs), forKey: Keys.memoryEnabledProviderIDs)
        defaults.set(Self.normalizedStringList(memoryDetectedSourceFolderIDs), forKey: Keys.memoryDetectedSourceFolderIDs)
        defaults.set(Self.normalizedStringList(memoryEnabledSourceFolderIDs), forKey: Keys.memoryEnabledSourceFolderIDs)
        defaults.set(promptRewriteProviderModeRawValue, forKey: Keys.promptRewriteProviderMode)
        defaults.set(promptRewriteOpenAIModel.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.promptRewriteOpenAIModel)
        defaults.set(promptRewriteOpenAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.promptRewriteOpenAIBaseURL)
        defaults.set(promptRewriteModelByProvider, forKey: Keys.promptRewriteModelByProvider)
        defaults.set(promptRewriteBaseURLByProvider, forKey: Keys.promptRewriteBaseURLByProvider)
        defaults.set(promptRewriteRequestTimeoutSeconds, forKey: Keys.promptRewriteRequestTimeoutSeconds)
        defaults.set(promptRewriteAlwaysConvertToMarkdown, forKey: Keys.promptRewriteAlwaysConvertToMarkdown)
        defaults.set(promptRewriteStylePresetRawValue, forKey: Keys.promptRewriteStylePreset)
        defaults.set(
            promptRewriteCustomStyleInstructions.trimmingCharacters(in: .whitespacesAndNewlines),
            forKey: Keys.promptRewriteCustomStyleInstructions
        )
        defaults.set(promptRewriteConversationHistoryEnabled, forKey: Keys.promptRewriteConversationHistoryEnabled)
        defaults.set(promptRewriteConversationTimeoutMinutes, forKey: Keys.promptRewriteConversationTimeoutMinutes)
        defaults.set(promptRewriteConversationTurnLimit, forKey: Keys.promptRewriteConversationTurnLimit)
        defaults.set(
            promptRewriteConversationPinnedContextID.trimmingCharacters(in: .whitespacesAndNewlines),
            forKey: Keys.promptRewriteConversationPinnedContextID
        )
        defaults.set(
            Self.normalizedStringList(promptRewriteConversationHistoryDisabledContextIDs),
            forKey: Keys.promptRewriteConversationHistoryDisabledContextIDs
        )
        defaults.set(
            promptRewriteCrossIDEConversationSharingEnabled,
            forKey: Keys.promptRewriteCrossIDEConversationSharingEnabled
        )
        defaults.set(
            googleAIStudioImageGenerationModel.trimmingCharacters(in: .whitespacesAndNewlines),
            forKey: Keys.googleAIStudioImageGenerationModel
        )
        defaults.set(localAISetupCompleted, forKey: Keys.localAISetupCompleted)
        defaults.set(localAISelectedModelID.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.localAISelectedModelID)
        defaults.set(localAIManagedRuntimeEnabled, forKey: Keys.localAIManagedRuntimeEnabled)
        defaults.set(localAIRuntimeVersion.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.localAIRuntimeVersion)
        defaults.set(localAILastHealthCheckEpoch, forKey: Keys.localAILastHealthCheckEpoch)
        defaults.set(assistantBetaEnabled, forKey: Keys.assistantBetaEnabled)
        defaults.set(assistantVoiceTaskEntryEnabled, forKey: Keys.assistantVoiceTaskEntryEnabled)
        defaults.set(assistantFloatingHUDEnabled, forKey: Keys.assistantFloatingHUDEnabled)
        defaults.set(assistantCompactPresentationStyleRawValue, forKey: Keys.assistantCompactPresentationStyle)
        defaults.set(assistantCompactSidebarEdgeRawValue, forKey: Keys.assistantCompactSidebarEdge)
        defaults.set(assistantCompactSidebarPinned, forKey: Keys.assistantCompactSidebarPinned)
        defaults.set(assistantNotchHoverDelayRawValue, forKey: Keys.assistantNotchHoverDelay)
        defaults.set(assistantBetaWarningAcknowledged, forKey: Keys.assistantBetaWarningAcknowledged)
        defaults.set(assistantVoiceOutputEnabled, forKey: Keys.assistantVoiceOutputEnabled)
        defaults.set(assistantVoiceEngineRawValue, forKey: Keys.assistantVoiceEngine)
        defaults.set(assistantHumeVoiceID.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.assistantHumeVoiceID)
        defaults.set(assistantHumeVoiceName.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.assistantHumeVoiceName)
        defaults.set(assistantHumeVoiceSourceRawValue, forKey: Keys.assistantHumeVoiceSource)
        defaults.set(assistantHumeConversationConfigID.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.assistantHumeConversationConfigID)
        defaults.set(assistantHumeConversationConfigVersion, forKey: Keys.assistantHumeConversationConfigVersion)
        defaults.set(assistantTTSFallbackToMacOS, forKey: Keys.assistantTTSFallbackToMacOS)
        defaults.set(assistantTTSFallbackVoiceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.assistantTTSFallbackVoiceIdentifier)
        defaults.set(
            assistantInterruptCurrentSpeechOnNewReply,
            forKey: Keys.assistantInterruptCurrentSpeechOnNewReply
        )
        defaults.set(assistantBackendRawValue, forKey: Keys.assistantBackend)
        defaults.set(assistantPreferredModelID.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.assistantPreferredModelID)
        defaults.set(
            assistantPreferredSubagentModelID.trimmingCharacters(in: .whitespacesAndNewlines),
            forKey: Keys.assistantPreferredSubagentModelID
        )
        defaults.set(Self.normalizedStringList(assistantOwnedThreadIDs), forKey: Keys.assistantOwnedThreadIDs)
        defaults.set(assistantArchiveDefaultRetentionHours, forKey: Keys.assistantArchiveDefaultRetentionHours)
        defaults.set(Array(assistantAlwaysApprovedToolKinds), forKey: Keys.assistantAlwaysApprovedToolKinds)
        defaults.set(browserAutomationEnabled, forKey: Keys.browserAutomationEnabled)
        defaults.set(assistantComputerUseEnabled, forKey: Keys.assistantComputerUseEnabled)
        defaults.set(browserSelectedProfileID.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.browserSelectedProfileID)
        defaults.set(settingsLastViewedSection.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.settingsLastViewedSection)
        defaults.set(settingsGettingStartedDismissed, forKey: Keys.settingsGettingStartedDismissed)
        defaults.set(assistantCustomInstructions, forKey: Keys.assistantCustomInstructions)
        defaults.set(assistantMaxToolCallsPerTurn, forKey: Keys.assistantMaxToolCallsPerTurn)
        defaults.set(
            assistantMaxRepeatedCommandAttemptsPerTurn,
            forKey: Keys.assistantMaxRepeatedCommandAttemptsPerTurn
        )
        defaults.set(
            assistantTrackCodeChangesInGitRepos,
            forKey: Keys.assistantTrackCodeChangesInGitRepos
        )
        defaults.set(assistantMemoryEnabled, forKey: Keys.assistantMemoryEnabled)
        defaults.set(assistantMemoryReviewEnabled, forKey: Keys.assistantMemoryReviewEnabled)
        defaults.set(assistantMemorySummaryMaxChars, forKey: Keys.assistantMemorySummaryMaxChars)
        defaults.set(
            assistantNotesBackupFolderPath.trimmingCharacters(in: .whitespacesAndNewlines),
            forKey: Keys.assistantNotesBackupFolderPath
        )
        defaults.set(
            assistantNotesLastSuccessfulBackupEpoch,
            forKey: Keys.assistantNotesLastSuccessfulBackupEpoch
        )

        scheduleOnChangeNotificationIfNeeded()
    }

    private func performBatchedSave(_ updates: () -> Void) {
        saveSuppressionDepth += 1
        updates()
        saveSuppressionDepth = max(0, saveSuppressionDepth - 1)
        guard saveSuppressionDepth == 0 else { return }
        save()
    }

    static func restoredInteger(
        defaults: UserDefaults,
        key: String,
        defaultValue: Int
    ) -> Int {
        guard let stored = defaults.object(forKey: key) as? NSNumber else {
            return defaultValue
        }
        return stored.intValue
    }

    static func restoredAssistantCompactPresentationStyle(
        defaults: UserDefaults = .standard
    ) -> AssistantCompactPresentationStyle {
        guard let storedValue = defaults.string(forKey: Keys.assistantCompactPresentationStyle),
              let style = AssistantCompactPresentationStyle(rawValue: storedValue) else {
            return .orb
        }
        return style
    }

    static func restoredAssistantCompactSidebarEdge(
        defaults: UserDefaults = .standard
    ) -> AssistantCompactSidebarEdge {
        guard let storedValue = defaults.string(forKey: Keys.assistantCompactSidebarEdge),
              let edge = AssistantCompactSidebarEdge(rawValue: storedValue) else {
            return .left
        }
        return edge
    }

    static func restoredAssistantCompactSidebarPinned(
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard defaults.object(forKey: Keys.assistantCompactSidebarPinned) != nil else {
            return false
        }
        return defaults.bool(forKey: Keys.assistantCompactSidebarPinned)
    }

    private func scheduleOnChangeNotificationIfNeeded() {
        guard !isApplyingChanges else {
            pendingOnChangeWorkItem?.cancel()
            pendingOnChangeWorkItem = nil
            return
        }
        pendingOnChangeWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingOnChangeWorkItem = nil
            guard !self.isApplyingChanges else { return }
            self.onChange?()
        }
        pendingOnChangeWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.onChangeDebounceSeconds,
            execute: workItem
        )
    }

    var shortcutModifierFlags: NSEvent.ModifierFlags {
        ShortcutValidation.filteredModifierFlags(from: shortcutModifiers)
    }

    var holdToTalkShortcutDisplayString: String {
        ShortcutValidation.displaySegments(
            keyCode: shortcutKeyCode,
            modifiersRaw: shortcutModifiers
        )
        .joined(separator: " ")
    }

    var continuousToggleShortcutModifierFlags: NSEvent.ModifierFlags {
        ShortcutValidation.filteredModifierFlags(from: continuousToggleShortcutModifiers)
    }

    var assistantLiveVoiceShortcutModifierFlags: NSEvent.ModifierFlags {
        ShortcutValidation.filteredModifierFlags(from: assistantLiveVoiceShortcutModifiers)
    }

    var assistantCompactShortcutModifierFlags: NSEvent.ModifierFlags {
        ShortcutValidation.filteredModifierFlags(from: assistantCompactShortcutModifiers)
    }

    var recognitionMode: RecognitionMode {
        get { RecognitionMode(rawValue: recognitionModeRawValue) ?? .localOnly }
        set { recognitionModeRawValue = newValue.rawValue }
    }

    var textCleanupMode: TextCleanupMode {
        get { TextCleanupMode(rawValue: textCleanupModeRawValue) ?? .light }
        set { textCleanupModeRawValue = newValue.rawValue }
    }

    var waveformTheme: WaveformTheme {
        get { WaveformTheme(rawValue: waveformThemeRawValue) ?? .vibrantSpectrum }
        set { waveformThemeRawValue = newValue.rawValue }
    }

    var appChromeStyle: AppChromeStyle {
        get { AppChromeStyle(rawValue: appChromeStyleRawValue) ?? .glassHighContrast }
        set { appChromeStyleRawValue = newValue.rawValue }
    }

    var assistantCompactPresentationStyle: AssistantCompactPresentationStyle {
        get { AssistantCompactPresentationStyle(rawValue: assistantCompactPresentationStyleRawValue) ?? .orb }
        set { assistantCompactPresentationStyleRawValue = newValue.rawValue }
    }

    var assistantCompactSidebarEdge: AssistantCompactSidebarEdge {
        get { AssistantCompactSidebarEdge(rawValue: assistantCompactSidebarEdgeRawValue) ?? .left }
        set { assistantCompactSidebarEdgeRawValue = newValue.rawValue }
    }

    var assistantNotchHoverDelay: AssistantNotchHoverDelay {
        get { AssistantNotchHoverDelay(rawValue: assistantNotchHoverDelayRawValue) ?? .twoSeconds }
        set { assistantNotchHoverDelayRawValue = newValue.rawValue }
    }

    var assistantVoiceEngine: AssistantSpeechEngine {
        get { AssistantSpeechEngine(rawValue: assistantVoiceEngineRawValue) ?? .humeOctave }
        set { assistantVoiceEngineRawValue = newValue.rawValue }
    }

    var assistantHumeVoiceSource: AssistantHumeVoiceSource {
        get { AssistantHumeVoiceSource(rawValue: assistantHumeVoiceSourceRawValue) ?? .humeAI }
        set { assistantHumeVoiceSourceRawValue = newValue.rawValue }
    }

    var colorTheme: ColorTheme {
        get { ColorTheme(rawValue: colorThemeRawValue) ?? .ocean }
        set { colorThemeRawValue = newValue.rawValue }
    }

    var transcriptionEngine: TranscriptionEngineType {
        get { TranscriptionEngineType(rawValue: transcriptionEngineRawValue) ?? .appleSpeech }
        set { transcriptionEngineRawValue = newValue.rawValue }
    }

    var automationAPIDefaultSound: AutomationAPISound {
        get { AutomationAPISound(rawValue: automationAPIDefaultSoundRawValue) ?? .processing }
        set { automationAPIDefaultSoundRawValue = newValue.rawValue }
    }

    var automationAPIDefaultVoiceIdentifierOrNil: String? {
        let value = automationAPIDefaultVoiceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var automationAPIEnabledChannels: [AutomationAPIChannel] {
        var channels: [AutomationAPIChannel] = []
        if automationAPINotificationsEnabled {
            channels.append(.notification)
        }
        if automationAPISpeechEnabled {
            channels.append(.speech)
        }
        if automationAPISoundEnabled {
            channels.append(.sound)
        }
        return channels
    }

    var automationAPIServerConfiguration: AutomationAPIServerConfiguration {
        AutomationAPIServerConfiguration(
            enabled: automationAPIEnabled,
            port: automationAPIPort,
            token: automationAPIToken,
            defaultChannels: automationAPIEnabledChannels,
            defaultVoiceIdentifier: automationAPIDefaultVoiceIdentifierOrNil,
            defaultSound: automationAPIDefaultSound
        )
    }

    func isAutomationSourceEnabled(_ source: AutomationAPISource) -> Bool {
        switch source {
        case .claudeCode:
            return automationClaudeEnabled
        case .codexCLI:
            return automationCodexCLIEnabled
        case .codexCloud:
            return automationCodexCloudEnabled
        }
    }

    var cloudTranscriptionProvider: CloudTranscriptionProvider {
        get { CloudTranscriptionProvider(rawValue: cloudTranscriptionProviderRawValue) ?? .openAI }
        set { cloudTranscriptionProviderRawValue = newValue.rawValue }
    }

    var promptRewriteProviderMode: PromptRewriteProviderMode {
        get { PromptRewriteProviderMode(rawValue: promptRewriteProviderModeRawValue) ?? .openAI }
        set { promptRewriteProviderModeRawValue = newValue.rawValue }
    }

    var promptRewriteStylePreset: PromptRewriteStylePreset {
        get { PromptRewriteStylePreset(rawValue: promptRewriteStylePresetRawValue) ?? .balanced }
        set { promptRewriteStylePresetRawValue = newValue.rawValue }
    }

    func hasPromptRewriteOAuthSession(for providerMode: PromptRewriteProviderMode) -> Bool {
        PromptRewriteOAuthCredentialStore.loadSession(for: providerMode) != nil
    }

    func hasPromptRewriteAPIKey(for providerMode: PromptRewriteProviderMode) -> Bool {
        guard providerMode.requiresAPIKey else { return true }
        let key = Self.loadPromptRewriteProviderAPIKey(for: providerMode)
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasGoogleAIStudioAPIKey: Bool {
        !googleAIStudioAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func hasCloudTranscriptionAPIKey(for provider: CloudTranscriptionProvider) -> Bool {
        guard provider.requiresAPIKey else { return true }
        let key = Self.loadCloudTranscriptionProviderAPIKey(for: provider)
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func applyCloudTranscriptionProviderDefaultsIfNeeded(force: Bool) {
        let provider = cloudTranscriptionProvider
        let normalizedModel = cloudTranscriptionModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if force || normalizedModel.isEmpty {
            cloudTranscriptionModel = provider.defaultModel
        }

        let normalizedBaseURL = cloudTranscriptionBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if force || normalizedBaseURL.isEmpty {
            cloudTranscriptionBaseURL = provider.defaultBaseURL
        }
    }

    var googleAIStudioImageGenerationModelResolved: String {
        googleAIStudioImageGenerationModel.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? Self.googleAIStudioImageGenerationDefaultModel
    }

    var geminiImageGenerationConfiguration: GeminiImageGenerationConfiguration {
        GeminiImageGenerationConfiguration(
            apiKey: googleAIStudioAPIKey.trimmingCharacters(in: .whitespacesAndNewlines),
            model: googleAIStudioImageGenerationModelResolved,
            baseURL: CloudTranscriptionProvider.gemini.defaultBaseURL,
            requestTimeoutSeconds: 90
        )
    }

    var automationAPIToken: String {
        get { Self.loadAutomationAPIToken() }
        set {
            Self.storeAutomationAPIToken(newValue)
            save()
        }
    }

    var telegramBotToken: String {
        get { Self.loadTelegramBotToken() }
        set {
            let previousValue = Self.loadTelegramBotToken().trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedNewValue = newValue.trimmingCharacters(in: .whitespacesAndNewlines)

            if previousValue != normalizedNewValue {
                clearTelegramPendingPairing()
                clearTelegramRemoteOwner()
                telegramLastProcessedUpdateID = 0
                telegramTrackedMessageIDs = []
            }

            Self.storeTelegramBotToken(normalizedNewValue)
            save()
        }
    }

    var telegramLastProcessedUpdateID: Int {
        get { defaults.integer(forKey: Keys.telegramLastProcessedUpdateID) }
        set { defaults.set(newValue, forKey: Keys.telegramLastProcessedUpdateID) }
    }

    var telegramTrackedMessageIDs: [Int] {
        get {
            let stored = defaults.array(forKey: Keys.telegramTrackedMessageIDs) as? [Int] ?? []
            return Self.normalizedTelegramMessageIDs(stored)
        }
        set {
            defaults.set(Self.normalizedTelegramMessageIDs(newValue), forKey: Keys.telegramTrackedMessageIDs)
        }
    }

    var hasTelegramRemoteOwner: Bool {
        telegramOwnerUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && telegramOwnerChatID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var hasTelegramPendingPairing: Bool {
        telegramPendingUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && telegramPendingChatID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    func approveTelegramPendingPairing() {
        guard hasTelegramPendingPairing else { return }
        performBatchedSave {
            telegramOwnerUserID = telegramPendingUserID
            telegramOwnerChatID = telegramPendingChatID
            telegramPendingUserID = ""
            telegramPendingChatID = ""
            telegramPendingDisplayName = ""
        }
    }

    func clearTelegramPendingPairing() {
        performBatchedSave {
            telegramPendingUserID = ""
            telegramPendingChatID = ""
            telegramPendingDisplayName = ""
        }
    }

    func clearTelegramRemoteOwner() {
        performBatchedSave {
            telegramOwnerUserID = ""
            telegramOwnerChatID = ""
            telegramTrackedMessageIDs = []
        }
    }

    func updateTelegramPendingPairing(
        userID: String,
        chatID: String,
        displayName: String
    ) {
        performBatchedSave {
            telegramPendingUserID = userID
            telegramPendingChatID = chatID
            telegramPendingDisplayName = displayName
        }
    }

    func ensureAutomationAPIToken() {
        if automationAPIToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rotateAutomationAPIToken()
        }
    }

    @discardableResult
    func rotateAutomationAPIToken() -> String {
        let token = Self.generateAutomationAPIToken()
        Self.storeAutomationAPIToken(token)
        save()
        return token
    }

    func isPromptRewriteProviderConnected(_ providerMode: PromptRewriteProviderMode) -> Bool {
        if providerMode.supportsOAuthSignIn, hasPromptRewriteOAuthSession(for: providerMode) {
            return true
        }
        if providerMode.requiresAPIKey {
            return hasPromptRewriteAPIKey(for: providerMode)
        }
        return true
    }

    func clearPromptRewriteOAuthSession(for providerMode: PromptRewriteProviderMode) {
        PromptRewriteOAuthCredentialStore.deleteSession(for: providerMode)
    }

    func applyPromptRewriteProviderDefaultsIfNeeded(force: Bool) {
        let mode = promptRewriteProviderMode

        let normalizedModel = promptRewriteOpenAIModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if force || normalizedModel.isEmpty {
            promptRewriteOpenAIModel = mode.defaultModel
        }

        let normalizedBaseURL = promptRewriteOpenAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if force || normalizedBaseURL.isEmpty {
            promptRewriteOpenAIBaseURL = mode.defaultBaseURL
        }
    }

    private func persistPromptRewriteProviderConfiguration(forRawValue rawValue: String) {
        guard let mode = PromptRewriteProviderMode(rawValue: rawValue) else { return }

        let normalizedModel = promptRewriteOpenAIModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedModel.isEmpty {
            promptRewriteModelByProvider.removeValue(forKey: mode.rawValue)
        } else {
            promptRewriteModelByProvider[mode.rawValue] = normalizedModel
        }

        let normalizedBaseURL = promptRewriteOpenAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedBaseURL.isEmpty {
            promptRewriteBaseURLByProvider.removeValue(forKey: mode.rawValue)
        } else {
            promptRewriteBaseURLByProvider[mode.rawValue] = normalizedBaseURL
        }
    }

    private func restorePromptRewriteProviderConfiguration(for mode: PromptRewriteProviderMode) {
        let restoredModel = promptRewriteModelByProvider[mode.rawValue] ?? mode.defaultModel
        let restoredBaseURL = promptRewriteBaseURLByProvider[mode.rawValue] ?? mode.defaultBaseURL
        let hasOAuthSession = mode.supportsOAuthSignIn && hasPromptRewriteOAuthSession(for: mode)
        let hasAPIKey = mode.requiresAPIKey && hasPromptRewriteAPIKey(for: mode)
        let sanitizedConfiguration = Self.sanitizedPromptRewriteProviderConfiguration(
            mode: mode,
            model: restoredModel,
            baseURL: restoredBaseURL,
            hasOAuthSession: hasOAuthSession,
            hasAPIKey: hasAPIKey
        )
        promptRewriteModelByProvider[mode.rawValue] = sanitizedConfiguration.model
        promptRewriteBaseURLByProvider[mode.rawValue] = sanitizedConfiguration.baseURL
        if promptRewriteOpenAIModel != sanitizedConfiguration.model {
            promptRewriteOpenAIModel = sanitizedConfiguration.model
        }
        if promptRewriteOpenAIBaseURL != sanitizedConfiguration.baseURL {
            promptRewriteOpenAIBaseURL = sanitizedConfiguration.baseURL
        }
    }

    func applyLocalAIDefaults(selectedModelID: String) {
        let normalizedModelID = selectedModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedModelID.isEmpty else { return }

        promptRewriteProviderMode = .ollama
        promptRewriteOpenAIBaseURL = PromptRewriteProviderMode.ollama.defaultBaseURL
        promptRewriteOpenAIModel = normalizedModelID
        promptRewriteEnabled = true
        let memoryFeatureEnabled = ProcessInfo.processInfo.environment["OPENASSIST_FEATURE_AI_MEMORY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let memoryFeatureEnabled,
           ["1", "true", "yes", "on"].contains(memoryFeatureEnabled) {
            memoryIndexingEnabled = true
        }

        localAISelectedModelID = normalizedModelID
        localAISetupCompleted = true
        localAIManagedRuntimeEnabled = true
        localAILastHealthCheckEpoch = Date().timeIntervalSince1970
    }

    func isPromptRewriteConversationHistoryEnabled(forContextID contextID: String) -> Bool {
        guard promptRewriteConversationHistoryEnabled else { return false }
        let normalizedID = Self.normalizedIdentifier(contextID)
        guard !normalizedID.isEmpty else { return true }
        return !promptRewriteConversationHistoryDisabledContextIDs.contains(normalizedID)
    }

    func setPromptRewriteConversationHistoryEnabled(_ isEnabled: Bool, forContextID contextID: String) {
        let normalizedID = Self.normalizedIdentifier(contextID)
        guard !normalizedID.isEmpty else { return }

        var updated = Set(promptRewriteConversationHistoryDisabledContextIDs)
        if isEnabled {
            updated.remove(normalizedID)
        } else {
            updated.insert(normalizedID)
        }
        promptRewriteConversationHistoryDisabledContextIDs = Self.normalizedStringList(Array(updated))
    }

    func isMemoryProviderEnabled(_ providerID: String) -> Bool {
        let normalizedID = Self.normalizedIdentifier(providerID)
        guard !normalizedID.isEmpty else { return false }
        return memoryEnabledProviderIDs.contains(normalizedID)
    }

    func setMemoryProviderEnabled(_ providerID: String, enabled: Bool) {
        let normalizedID = Self.normalizedIdentifier(providerID)
        guard !normalizedID.isEmpty else { return }

        var updated = Set(memoryEnabledProviderIDs)
        if enabled {
            updated.insert(normalizedID)
        } else {
            updated.remove(normalizedID)
        }
        memoryEnabledProviderIDs = Self.normalizedStringList(Array(updated))
    }

    func isMemorySourceFolderEnabled(_ folderID: String) -> Bool {
        let normalizedID = Self.normalizedIdentifier(folderID)
        guard !normalizedID.isEmpty else { return false }
        return memoryEnabledSourceFolderIDs.contains(normalizedID)
    }

    func setMemorySourceFolderEnabled(_ folderID: String, enabled: Bool) {
        let normalizedID = Self.normalizedIdentifier(folderID)
        guard !normalizedID.isEmpty else { return }

        var updated = Set(memoryEnabledSourceFolderIDs)
        if enabled {
            updated.insert(normalizedID)
        } else {
            updated.remove(normalizedID)
        }
        memoryEnabledSourceFolderIDs = Self.normalizedStringList(Array(updated))
    }

    func updateDetectedMemoryProviders(_ providerIDs: [String]) {
        let normalizedProviders = Self.normalizedStringList(providerIDs)
        let previousDetected = Set(memoryDetectedProviderIDs)
        let previousEnabled = Set(memoryEnabledProviderIDs)
        let removedProviders = previousDetected.subtracting(normalizedProviders)

        memoryDetectedProviderIDs = normalizedProviders
        if !removedProviders.isEmpty {
            // Discovery catalog changed (providers disappeared). Seed currently detected providers as enabled
            // so stale disabled state from an older catalog does not suppress newly detected indexing sources.
            memoryEnabledProviderIDs = normalizedProviders
            return
        }
        memoryEnabledProviderIDs = normalizedProviders.filter { providerID in
            if previousDetected.contains(providerID) {
                return previousEnabled.contains(providerID)
            }
            return true
        }
    }

    func updateDetectedMemorySourceFolders(_ sourceFolderIDs: [String]) {
        let normalizedFolders = Self.normalizedStringList(sourceFolderIDs)
        let previousDetected = Set(memoryDetectedSourceFolderIDs)
        let previousEnabled = Set(memoryEnabledSourceFolderIDs)
        let removedFolders = previousDetected.subtracting(normalizedFolders)

        memoryDetectedSourceFolderIDs = normalizedFolders
        if !removedFolders.isEmpty {
            // Same recovery behavior as providers: when the folder catalog changes shape, reseed enabled
            // state from current detections so stale disabled data cannot leave every folder unselected.
            memoryEnabledSourceFolderIDs = normalizedFolders
            return
        }
        memoryEnabledSourceFolderIDs = normalizedFolders.filter { folderID in
            if previousDetected.contains(folderID) {
                return previousEnabled.contains(folderID)
            }
            return true
        }
    }

    private static func normalizedIdentifier(_ rawValue: String) -> String {
        rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedStringList(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var cleaned: [String] = []
        cleaned.reserveCapacity(values.count)

        for rawValue in values {
            let normalized = normalizedIdentifier(rawValue)
            guard !normalized.isEmpty else { continue }
            if seen.insert(normalized).inserted {
                cleaned.append(normalized)
            }
        }

        return cleaned.sorted { lhs, rhs in
            lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }

    private static func normalizedTelegramMessageIDs(_ values: [Int]) -> [Int] {
        var seen = Set<Int>()
        let normalized = values.filter { value in
            guard value > 0 else { return false }
            return seen.insert(value).inserted
        }

        if normalized.count > 400 {
            return Array(normalized.suffix(400))
        }

        return normalized
    }

    private static func normalizedProviderScopedStringDictionary(_ values: [String: Any]?) -> [String: String] {
        guard let values else { return [:] }
        let validProviderIDs = Set(PromptRewriteProviderMode.allCases.map(\.rawValue))
        var normalized: [String: String] = [:]
        normalized.reserveCapacity(values.count)

        for (rawKey, rawValue) in values {
            let providerID = normalizedIdentifier(rawKey)
            guard validProviderIDs.contains(providerID) else { continue }
            guard let rawString = rawValue as? String else { continue }
            let value = normalizedIdentifier(rawString)
            guard !value.isEmpty else { continue }
            normalized[providerID] = value
        }

        return normalized
    }

    private static func sanitizedCloudTranscriptionConfiguration(
        provider: CloudTranscriptionProvider,
        model: String,
        baseURL: String
    ) -> (model: String, baseURL: String) {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedModel = trimmedModel.isEmpty ? provider.defaultModel : trimmedModel
        let resolvedBaseURL = trimmedBaseURL.isEmpty ? provider.defaultBaseURL : trimmedBaseURL
        return (resolvedModel, resolvedBaseURL)
    }

    private static let openAIOAuthFallbackModelID = "gpt-5.2"
    static let googleAIStudioAPIKeychainAccount = "google-ai-studio-api-key"
    static let googleAIStudioImageGenerationDefaultModel = "gemini-2.5-flash-image"

    private static func isOpenAIOAuthCompatibleModelID(_ modelID: String) -> Bool {
        let normalized = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        if normalized.contains("codex") {
            return true
        }
        return normalized == openAIOAuthFallbackModelID
    }

    private static func sanitizedPromptRewriteProviderConfiguration(
        mode: PromptRewriteProviderMode,
        model: String,
        baseURL: String,
        hasOAuthSession: Bool,
        hasAPIKey: Bool
    ) -> (model: String, baseURL: String) {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        var resolvedModel = trimmedModel.isEmpty ? mode.defaultModel : trimmedModel
        var resolvedBaseURL = trimmedBaseURL.isEmpty ? mode.defaultBaseURL : trimmedBaseURL

        guard mode == .openAI else {
            return (resolvedModel, resolvedBaseURL)
        }

        let usingOpenAIOAuthOnly = hasOAuthSession && !hasAPIKey
        guard usingOpenAIOAuthOnly else {
            return (resolvedModel, resolvedBaseURL)
        }

        resolvedBaseURL = mode.defaultBaseURL
        if !isOpenAIOAuthCompatibleModelID(resolvedModel) {
            resolvedModel = openAIOAuthFallbackModelID
        }
        return (resolvedModel, resolvedBaseURL)
    }

    private static let cloudTranscriptionProviderAPIKeychainService = "com.developingadventures.OpenAssist"
    private static let cloudTranscriptionProviderAPIKeychainAccountPrefix = "cloud-transcription-provider-api-key"
    private static let automationAPIKeychainService = "com.developingadventures.OpenAssist"
    private static let automationAPIKeychainAccount = "automation-api-bearer-token"
    private static let telegramBotTokenKeychainService = "com.developingadventures.OpenAssist"
    private static let telegramBotTokenKeychainAccount = "telegram-bot-token"
    private static let assistantHumeCredentialKeychainService = "com.developingadventures.OpenAssist"
    private static let assistantHumeAPIKeychainAccount = "assistant-hume-api-key"
    private static let assistantHumeSecretKeychainAccount = "assistant-hume-secret-key"

    private static func generateAutomationAPIToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)

        if status == errSecSuccess {
            let hexString = bytes.map { String(format: "%02x", $0) }.joined()
            return "ks_" + hexString
        }

        let fallback = UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        return "ks_" + fallback
    }

    private static func loadAutomationAPIToken() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: automationAPIKeychainService,
            kSecAttrAccount as String: automationAPIKeychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return ""
        }
        return value
    }

    private static func storeAutomationAPIToken(_ rawValue: String) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            deleteAutomationAPIToken()
            return
        }

        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: automationAPIKeychainService,
            kSecAttrAccount as String: automationAPIKeychainAccount
        ]

        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }

        if updateStatus == errSecItemNotFound {
            var create = query
            create[kSecValueData as String] = data
            _ = SecItemAdd(create as CFDictionary, nil)
        }
    }

    private static func deleteAutomationAPIToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: automationAPIKeychainService,
            kSecAttrAccount as String: automationAPIKeychainAccount
        ]
        _ = SecItemDelete(query as CFDictionary)
    }

    private static func loadTelegramBotToken() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: telegramBotTokenKeychainService,
            kSecAttrAccount as String: telegramBotTokenKeychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return ""
        }
        return value
    }

    private static func storeTelegramBotToken(_ rawValue: String) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            deleteTelegramBotToken()
            return
        }

        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: telegramBotTokenKeychainService,
            kSecAttrAccount as String: telegramBotTokenKeychainAccount
        ]

        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }

        if updateStatus == errSecItemNotFound {
            var create = query
            create[kSecValueData as String] = data
            _ = SecItemAdd(create as CFDictionary, nil)
        }
    }

    private static func deleteTelegramBotToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: telegramBotTokenKeychainService,
            kSecAttrAccount as String: telegramBotTokenKeychainAccount
        ]
        _ = SecItemDelete(query as CFDictionary)
    }

    static func cloudTranscriptionKeychainAccount(for provider: CloudTranscriptionProvider) -> String {
        if provider == .gemini {
            return googleAIStudioAPIKeychainAccount
        }
        let normalized = provider.rawValue
            .lowercased()
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        return "\(cloudTranscriptionProviderAPIKeychainAccountPrefix).\(normalized)"
    }

    private static func loadCloudTranscriptionProviderAPIKey(for provider: CloudTranscriptionProvider) -> String {
        guard provider.requiresAPIKey else {
            return ""
        }
        if provider == .gemini {
            return loadGoogleAIStudioAPIKey()
        }
        let account = cloudTranscriptionKeychainAccount(for: provider)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: cloudTranscriptionProviderAPIKeychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return ""
        }
        return value
    }

    private static func storeCloudTranscriptionProviderAPIKey(
        _ rawValue: String,
        for provider: CloudTranscriptionProvider
    ) {
        guard provider.requiresAPIKey else {
            deleteCloudTranscriptionProviderAPIKey(for: provider)
            return
        }
        if provider == .gemini {
            storeGoogleAIStudioAPIKey(rawValue)
            return
        }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            deleteCloudTranscriptionProviderAPIKey(for: provider)
            return
        }

        let data = Data(value.utf8)
        let account = cloudTranscriptionKeychainAccount(for: provider)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: cloudTranscriptionProviderAPIKeychainService,
            kSecAttrAccount as String: account
        ]

        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }

        if updateStatus == errSecItemNotFound {
            var create = query
            create[kSecValueData as String] = data
            _ = SecItemAdd(create as CFDictionary, nil)
        }
    }

    private static func deleteCloudTranscriptionProviderAPIKey(for provider: CloudTranscriptionProvider) {
        if provider == .gemini {
            deleteGoogleAIStudioAPIKey()
            return
        }
        let account = cloudTranscriptionKeychainAccount(for: provider)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: cloudTranscriptionProviderAPIKeychainService,
            kSecAttrAccount as String: account
        ]
        _ = SecItemDelete(query as CFDictionary)
    }

    private static func deleteAllCloudTranscriptionProviderAPIKeys() {
        for provider in CloudTranscriptionProvider.allCases {
            deleteCloudTranscriptionProviderAPIKey(for: provider)
        }
    }

    private static let promptRewriteProviderAPIKeychainService = "com.developingadventures.OpenAssist"
    private static let promptRewriteProviderAPIKeychainAccountPrefix = "prompt-rewrite-provider-api-key"
    private static let legacyPromptRewriteOpenAIAPIKeychainAccount = "prompt-rewrite-openai-api-key"
    private static let legacyPromptRewriteGoogleAPIKeychainAccount = "prompt-rewrite-provider-api-key.google-ai-studio-gemini"
    private static let legacyCloudTranscriptionGeminiAPIKeychainAccount = "cloud-transcription-provider-api-key.google-gemini-ai-studio"

    static func keychainAccount(for providerMode: PromptRewriteProviderMode) -> String {
        if providerMode == .google {
            return googleAIStudioAPIKeychainAccount
        }
        let normalized = providerMode.rawValue
            .lowercased()
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .replacingOccurrences(of: " ", with: "-")
        return "\(promptRewriteProviderAPIKeychainAccountPrefix).\(normalized)"
    }

    private static func loadPromptRewriteProviderAPIKey(for providerMode: PromptRewriteProviderMode) -> String {
        guard providerMode.requiresAPIKey else { return "" }
        if providerMode == .google {
            return loadGoogleAIStudioAPIKey()
        }
        let account = keychainAccount(for: providerMode)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: promptRewriteProviderAPIKeychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status != errSecSuccess {
            if providerMode == .openAI {
                let legacyQuery: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: promptRewriteProviderAPIKeychainService,
                    kSecAttrAccount as String: legacyPromptRewriteOpenAIAPIKeychainAccount,
                    kSecReturnData as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne
                ]
                var legacyItem: CFTypeRef?
                let legacyStatus = SecItemCopyMatching(legacyQuery as CFDictionary, &legacyItem)
                guard legacyStatus == errSecSuccess,
                      let legacyData = legacyItem as? Data,
                      let legacyValue = String(data: legacyData, encoding: .utf8) else {
                    return ""
                }
                storePromptRewriteProviderAPIKey(legacyValue, for: providerMode)
                return legacyValue
            }
            return ""
        }
        guard let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return ""
        }
        return value
    }

    private static func storePromptRewriteProviderAPIKey(
        _ rawValue: String,
        for providerMode: PromptRewriteProviderMode
    ) {
        guard providerMode.requiresAPIKey else {
            deletePromptRewriteProviderAPIKey(for: providerMode)
            return
        }
        if providerMode == .google {
            storeGoogleAIStudioAPIKey(rawValue)
            return
        }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            deletePromptRewriteProviderAPIKey(for: providerMode)
            return
        }

        let data = Data(value.utf8)
        let account = keychainAccount(for: providerMode)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: promptRewriteProviderAPIKeychainService,
            kSecAttrAccount as String: account
        ]

        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }

        if updateStatus == errSecItemNotFound {
            var create = query
            create[kSecValueData as String] = data
            _ = SecItemAdd(create as CFDictionary, nil)
        }

        if providerMode == .openAI {
            let legacyQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: promptRewriteProviderAPIKeychainService,
                kSecAttrAccount as String: legacyPromptRewriteOpenAIAPIKeychainAccount
            ]
            _ = SecItemDelete(legacyQuery as CFDictionary)
        }
    }

    private static func deletePromptRewriteProviderAPIKey(for providerMode: PromptRewriteProviderMode) {
        if providerMode == .google {
            deleteGoogleAIStudioAPIKey()
            return
        }
        let account = keychainAccount(for: providerMode)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: promptRewriteProviderAPIKeychainService,
            kSecAttrAccount as String: account
        ]
        _ = SecItemDelete(query as CFDictionary)
    }

    private static func deleteAllPromptRewriteProviderAPIKeys() {
        for providerMode in PromptRewriteProviderMode.allCases {
            deletePromptRewriteProviderAPIKey(for: providerMode)
        }
        let legacyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: promptRewriteProviderAPIKeychainService,
            kSecAttrAccount as String: legacyPromptRewriteOpenAIAPIKeychainAccount
        ]
        _ = SecItemDelete(legacyQuery as CFDictionary)
    }

    private static func loadGoogleAIStudioAPIKey() -> String {
        let sharedQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: promptRewriteProviderAPIKeychainService,
            kSecAttrAccount as String: googleAIStudioAPIKeychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let sharedStatus = SecItemCopyMatching(sharedQuery as CFDictionary, &item)
        if sharedStatus == errSecSuccess,
           let data = item as? Data,
           let value = String(data: data, encoding: .utf8) {
            return value
        }

        let legacyAccounts = [
            legacyPromptRewriteGoogleAPIKeychainAccount,
            legacyCloudTranscriptionGeminiAPIKeychainAccount
        ]
        for account in legacyAccounts {
            let legacyQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: promptRewriteProviderAPIKeychainService,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var legacyItem: CFTypeRef?
            let legacyStatus = SecItemCopyMatching(legacyQuery as CFDictionary, &legacyItem)
            guard legacyStatus == errSecSuccess,
                  let legacyData = legacyItem as? Data,
                  let legacyValue = String(data: legacyData, encoding: .utf8) else {
                continue
            }
            storeGoogleAIStudioAPIKey(legacyValue)
            _ = SecItemDelete(legacyQuery as CFDictionary)
            return legacyValue
        }

        return ""
    }

    private static func storeGoogleAIStudioAPIKey(_ rawValue: String) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            deleteGoogleAIStudioAPIKey()
            return
        }

        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: promptRewriteProviderAPIKeychainService,
            kSecAttrAccount as String: googleAIStudioAPIKeychainAccount
        ]

        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }

        if updateStatus == errSecItemNotFound {
            var create = query
            create[kSecValueData as String] = data
            _ = SecItemAdd(create as CFDictionary, nil)
        }
    }

    private static func deleteGoogleAIStudioAPIKey() {
        let accounts = [
            googleAIStudioAPIKeychainAccount,
            legacyPromptRewriteGoogleAPIKeychainAccount,
            legacyCloudTranscriptionGeminiAPIKeychainAccount
        ]
        for account in accounts {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: promptRewriteProviderAPIKeychainService,
                kSecAttrAccount as String: account
            ]
            _ = SecItemDelete(query as CFDictionary)
        }
    }

    private static func loadAssistantHumeCredential(account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: assistantHumeCredentialKeychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return ""
        }
        return value
    }

    private static func storeAssistantHumeCredential(_ rawValue: String, account: String) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            deleteAssistantHumeCredential(account: account)
            return
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: assistantHumeCredentialKeychainService,
            kSecAttrAccount as String: account
        ]
        let data = Data(value.utf8)

        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }

        if updateStatus == errSecItemNotFound {
            var create = query
            create[kSecValueData as String] = data
            _ = SecItemAdd(create as CFDictionary, nil)
        }
    }

    private static func deleteAssistantHumeCredential(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: assistantHumeCredentialKeychainService,
            kSecAttrAccount as String: account
        ]
        _ = SecItemDelete(query as CFDictionary)
    }

    /// Resets all permissions, deletes local app data, and removes the app bundle when possible.
    static func resetAndUninstall(
        deleteDownloadedModels: Bool = false,
        deleteLearnedCorrections: Bool = false,
        deleteMemories: Bool = false,
        deleteProviderCredentials: Bool = false
    ) {
        if deleteProviderCredentials {
            deleteAllCloudTranscriptionProviderAPIKeys()
            deleteAllPromptRewriteProviderAPIKeys()
            deleteAutomationAPIToken()
            PromptRewriteOAuthCredentialStore.deleteAllSessions()
        }

        let currentBundleID = Bundle.main.bundleIdentifier ?? "com.developingadventures.OpenAssist"
        let appName = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "Open Assist"
        let bundleIDs = Array(
            Set([
                currentBundleID,
                "com.developingadventures.OpenAssist"
            ])
        )
        let appRemovalPaths = Array(
            Set([
                Bundle.main.bundlePath,
                "/Applications/\(appName).app",
                "\(NSHomeDirectory())/Applications/\(appName).app"
            ])
        )

        // Build a shell script that:
        // 1. Resets TCC permissions (Accessibility, Microphone, Speech Recognition)
        // 2. Removes UserDefaults + caches + app data (optionally preserving downloaded whisper models)
        // 3. Removes app logs and saved state
        let resetCommands = bundleIDs.flatMap { bundleID in
            [
                "tccutil reset Accessibility \(shellSingleQuoted(bundleID)) 2>/dev/null || true",
                "tccutil reset Microphone \(shellSingleQuoted(bundleID)) 2>/dev/null || true",
                "tccutil reset SpeechRecognition \(shellSingleQuoted(bundleID)) 2>/dev/null || true"
            ]
        }.joined(separator: "; ")

        let prefsCleanupCommands = bundleIDs.map { bundleID in
            "rm -f \(shellSingleQuoted("\(NSHomeDirectory())/Library/Preferences/\(bundleID).plist"))"
        }.joined(separator: "; ")

        let cacheCleanupCommands = bundleIDs.map { bundleID in
            "rm -rf \(shellSingleQuoted("\(NSHomeDirectory())/Library/Caches/\(bundleID)"))"
        }.joined(separator: "; ")

        let savedStateCleanupCommands = bundleIDs.map { bundleID in
            "rm -rf \(shellSingleQuoted("\(NSHomeDirectory())/Library/Saved Application State/\(bundleID).savedState"))"
        }.joined(separator: "; ")

        let appSupportPath = "\(NSHomeDirectory())/Library/Application Support/OpenAssist"
        var appSupportCleanupCommands: [String] = []
        appSupportCleanupCommands.append("mkdir -p \(shellSingleQuoted(appSupportPath))")

        var findPreserveClauses: [String] = []
        if !deleteDownloadedModels {
            findPreserveClauses.append("! -name 'Models'")
            findPreserveClauses.append("! -name 'LocalAI'")
        }
        if !deleteMemories {
            findPreserveClauses.append("! -name 'Memory'")
        }
        let preserveExpression = findPreserveClauses.joined(separator: " ")
        appSupportCleanupCommands.append(
            "find \(shellSingleQuoted(appSupportPath)) -mindepth 1 -maxdepth 1 \(preserveExpression) -exec rm -rf {} +"
        )

        if deleteDownloadedModels {
            appSupportCleanupCommands.append(
                "rm -rf \(shellSingleQuoted("\(appSupportPath)/Models"))"
            )
            appSupportCleanupCommands.append(
                "rm -rf \(shellSingleQuoted("\(appSupportPath)/LocalAI"))"
            )
        } else if deleteLearnedCorrections {
            appSupportCleanupCommands.append(
                "rm -f \(shellSingleQuoted(AdaptiveCorrectionStore.storageFilePath()))"
            )
        }

        if deleteMemories {
            appSupportCleanupCommands.append(
                "rm -rf \(shellSingleQuoted("\(appSupportPath)/Memory"))"
            )
        }

        let appSupportCleanupSection = appSupportCleanupCommands.joined(separator: "; ")
        let logsCleanupCommand = "rm -rf \(shellSingleQuoted("\(NSHomeDirectory())/Library/Logs/OpenAssist"))"

        let script = """
        \(resetCommands); \
        \(prefsCleanupCommands); \
        \(cacheCleanupCommands); \
        \(savedStateCleanupCommands); \
        \(appSupportCleanupSection); \
        \(logsCleanupCommand)
        """

        executeShellCommand(script)

        var removalIssues: [String] = []
        for path in appRemovalPaths {
            if let message = removeItemAtPath(path) {
                removalIssues.append(message)
            }
        }

        guard removalIssues.isEmpty else {
            CrashReporter.logError("Uninstall app bundle removal issue(s): \(removalIssues.joined(separator: "; "))")
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Uninstall completed with manual cleanup"
            alert.informativeText = "Permissions and app data were reset, but Open Assist.app could not be removed automatically from all locations. Move it to Trash manually from Applications."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        // Successfully uninstalled — quit the app
        NSApplication.shared.terminate(nil)
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func executeShellCommand(_ command: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            CrashReporter.logError("Uninstall shell command failed: \(error)")
        }
    }

    private static func removeItemAtPath(_ path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path) else { return nil }

        do {
            try fileManager.trashItem(at: url, resultingItemURL: nil)
            return nil
        } catch {
            do {
                try fileManager.removeItem(at: url)
                return nil
            } catch {
                return "\(path): \(error.localizedDescription)"
            }
        }
    }

    func hasModifier(_ modifier: NSEvent.ModifierFlags) -> Bool {
        shortcutModifierFlags.contains(modifier)
    }

    func setModifier(_ modifier: NSEvent.ModifierFlags, enabled: Bool) {
        if enabled {
            shortcutModifiers |= modifier.rawValue
        } else {
            shortcutModifiers &= ~modifier.rawValue
        }
    }

    private static func normalizedShortcut(
        keyCode: UInt16,
        modifiersRaw: UInt,
        defaultKeyCode: UInt16,
        defaultModifiersRaw: UInt
    ) -> (keyCode: UInt16, modifiersRaw: UInt) {
        let filtered = ShortcutValidation.filteredModifierRawValue(from: modifiersRaw)
        if ShortcutValidation.isValid(keyCode: keyCode, modifiersRaw: filtered) {
            return (keyCode, filtered)
        }

        let fallbackFiltered = ShortcutValidation.filteredModifierRawValue(from: defaultModifiersRaw)
        return (defaultKeyCode, fallbackFiltered)
    }

    private static func shortcutsConflict(
        lhsKeyCode: UInt16,
        lhsModifiersRaw: UInt,
        rhsKeyCode: UInt16,
        rhsModifiersRaw: UInt
    ) -> Bool {
        lhsKeyCode == rhsKeyCode &&
            ShortcutValidation.filteredModifierRawValue(from: lhsModifiersRaw) ==
            ShortcutValidation.filteredModifierRawValue(from: rhsModifiersRaw)
    }

    private static func resolveContinuousToggleShortcut(
        keyCode: UInt16,
        modifiersRaw: UInt,
        holdToTalkKeyCode: UInt16,
        holdToTalkModifiersRaw: UInt
    ) -> (keyCode: UInt16, modifiersRaw: UInt) {
        let normalized = normalizedShortcut(
            keyCode: keyCode,
            modifiersRaw: modifiersRaw,
            defaultKeyCode: ContinuousToggleDefaults.keyCode,
            defaultModifiersRaw: ContinuousToggleDefaults.modifiers
        )

        if !shortcutsConflict(
            lhsKeyCode: normalized.keyCode,
            lhsModifiersRaw: normalized.modifiersRaw,
            rhsKeyCode: holdToTalkKeyCode,
            rhsModifiersRaw: holdToTalkModifiersRaw
        ) && !shortcutsConflict(
            lhsKeyCode: normalized.keyCode,
            lhsModifiersRaw: normalized.modifiersRaw,
            rhsKeyCode: PasteLastShortcut.keyCode,
            rhsModifiersRaw: PasteLastShortcut.modifiers
        ) {
            return normalized
        }

        let fallbacks: [(UInt16, UInt)] = [
            (ContinuousToggleDefaults.keyCode, ContinuousToggleDefaults.modifiers),
            (36, NSEvent.ModifierFlags([.command, .option]).rawValue), // Return
            (8, NSEvent.ModifierFlags([.command, .option, .control]).rawValue) // C
        ]

        for candidate in fallbacks {
            let normalizedCandidate = normalizedShortcut(
                keyCode: candidate.0,
                modifiersRaw: candidate.1,
                defaultKeyCode: ContinuousToggleDefaults.keyCode,
                defaultModifiersRaw: ContinuousToggleDefaults.modifiers
            )
            let conflictsHold = shortcutsConflict(
                lhsKeyCode: normalizedCandidate.keyCode,
                lhsModifiersRaw: normalizedCandidate.modifiersRaw,
                rhsKeyCode: holdToTalkKeyCode,
                rhsModifiersRaw: holdToTalkModifiersRaw
            )
            let conflictsPasteLast = shortcutsConflict(
                lhsKeyCode: normalizedCandidate.keyCode,
                lhsModifiersRaw: normalizedCandidate.modifiersRaw,
                rhsKeyCode: PasteLastShortcut.keyCode,
                rhsModifiersRaw: PasteLastShortcut.modifiers
            )
            if !conflictsHold && !conflictsPasteLast {
                return normalizedCandidate
            }
        }

        return normalized
    }

    private static func resolveAssistantLiveVoiceShortcut(
        keyCode: UInt16,
        modifiersRaw: UInt,
        holdToTalkKeyCode: UInt16,
        holdToTalkModifiersRaw: UInt,
        continuousToggleKeyCode: UInt16,
        continuousToggleModifiersRaw: UInt
    ) -> (keyCode: UInt16, modifiersRaw: UInt) {
        let normalized = normalizedShortcut(
            keyCode: keyCode,
            modifiersRaw: modifiersRaw,
            defaultKeyCode: AssistantLiveVoiceShortcutDefaults.keyCode,
            defaultModifiersRaw: AssistantLiveVoiceShortcutDefaults.modifiers
        )

        if !shortcutsConflict(
            lhsKeyCode: normalized.keyCode,
            lhsModifiersRaw: normalized.modifiersRaw,
            rhsKeyCode: holdToTalkKeyCode,
            rhsModifiersRaw: holdToTalkModifiersRaw
        ) && !shortcutsConflict(
            lhsKeyCode: normalized.keyCode,
            lhsModifiersRaw: normalized.modifiersRaw,
            rhsKeyCode: continuousToggleKeyCode,
            rhsModifiersRaw: continuousToggleModifiersRaw
        ) && !shortcutsConflict(
            lhsKeyCode: normalized.keyCode,
            lhsModifiersRaw: normalized.modifiersRaw,
            rhsKeyCode: PasteLastShortcut.keyCode,
            rhsModifiersRaw: PasteLastShortcut.modifiers
        ) {
            return normalized
        }

        let fallbacks: [(UInt16, UInt)] = [
            (AssistantLiveVoiceShortcutDefaults.keyCode, AssistantLiveVoiceShortcutDefaults.modifiers),
            (15, NSEvent.ModifierFlags([.command, .option, .control]).rawValue), // R
            (40, NSEvent.ModifierFlags([.command, .option, .control]).rawValue)  // K
        ]

        for candidate in fallbacks {
            let normalizedCandidate = normalizedShortcut(
                keyCode: candidate.0,
                modifiersRaw: candidate.1,
                defaultKeyCode: AssistantLiveVoiceShortcutDefaults.keyCode,
                defaultModifiersRaw: AssistantLiveVoiceShortcutDefaults.modifiers
            )
            let conflictsHold = shortcutsConflict(
                lhsKeyCode: normalizedCandidate.keyCode,
                lhsModifiersRaw: normalizedCandidate.modifiersRaw,
                rhsKeyCode: holdToTalkKeyCode,
                rhsModifiersRaw: holdToTalkModifiersRaw
            )
            let conflictsContinuous = shortcutsConflict(
                lhsKeyCode: normalizedCandidate.keyCode,
                lhsModifiersRaw: normalizedCandidate.modifiersRaw,
                rhsKeyCode: continuousToggleKeyCode,
                rhsModifiersRaw: continuousToggleModifiersRaw
            )
            let conflictsPasteLast = shortcutsConflict(
                lhsKeyCode: normalizedCandidate.keyCode,
                lhsModifiersRaw: normalizedCandidate.modifiersRaw,
                rhsKeyCode: PasteLastShortcut.keyCode,
                rhsModifiersRaw: PasteLastShortcut.modifiers
            )
            if !conflictsHold && !conflictsContinuous && !conflictsPasteLast {
                return normalizedCandidate
            }
        }

        return normalized
    }

    private static func resolveAssistantCompactShortcut(
        keyCode: UInt16,
        modifiersRaw: UInt,
        holdToTalkKeyCode: UInt16,
        holdToTalkModifiersRaw: UInt,
        continuousToggleKeyCode: UInt16,
        continuousToggleModifiersRaw: UInt,
        assistantLiveVoiceKeyCode: UInt16,
        assistantLiveVoiceModifiersRaw: UInt
    ) -> (keyCode: UInt16, modifiersRaw: UInt) {
        let normalized = normalizedShortcut(
            keyCode: keyCode,
            modifiersRaw: modifiersRaw,
            defaultKeyCode: AssistantCompactShortcutDefaults.keyCode,
            defaultModifiersRaw: AssistantCompactShortcutDefaults.modifiers
        )

        if !shortcutsConflict(
            lhsKeyCode: normalized.keyCode,
            lhsModifiersRaw: normalized.modifiersRaw,
            rhsKeyCode: holdToTalkKeyCode,
            rhsModifiersRaw: holdToTalkModifiersRaw
        ) && !shortcutsConflict(
            lhsKeyCode: normalized.keyCode,
            lhsModifiersRaw: normalized.modifiersRaw,
            rhsKeyCode: continuousToggleKeyCode,
            rhsModifiersRaw: continuousToggleModifiersRaw
        ) && !shortcutsConflict(
            lhsKeyCode: normalized.keyCode,
            lhsModifiersRaw: normalized.modifiersRaw,
            rhsKeyCode: assistantLiveVoiceKeyCode,
            rhsModifiersRaw: assistantLiveVoiceModifiersRaw
        ) && !shortcutsConflict(
            lhsKeyCode: normalized.keyCode,
            lhsModifiersRaw: normalized.modifiersRaw,
            rhsKeyCode: PasteLastShortcut.keyCode,
            rhsModifiersRaw: PasteLastShortcut.modifiers
        ) {
            return normalized
        }

        let fallbacks: [(UInt16, UInt)] = [
            (AssistantCompactShortcutDefaults.keyCode, AssistantCompactShortcutDefaults.modifiers),
            (11, NSEvent.ModifierFlags([.command, .option, .control]).rawValue), // B
            (40, NSEvent.ModifierFlags([.command, .option, .shift]).rawValue) // K
        ]

        for candidate in fallbacks {
            let normalizedCandidate = normalizedShortcut(
                keyCode: candidate.0,
                modifiersRaw: candidate.1,
                defaultKeyCode: AssistantCompactShortcutDefaults.keyCode,
                defaultModifiersRaw: AssistantCompactShortcutDefaults.modifiers
            )
            let conflictsHold = shortcutsConflict(
                lhsKeyCode: normalizedCandidate.keyCode,
                lhsModifiersRaw: normalizedCandidate.modifiersRaw,
                rhsKeyCode: holdToTalkKeyCode,
                rhsModifiersRaw: holdToTalkModifiersRaw
            )
            let conflictsContinuous = shortcutsConflict(
                lhsKeyCode: normalizedCandidate.keyCode,
                lhsModifiersRaw: normalizedCandidate.modifiersRaw,
                rhsKeyCode: continuousToggleKeyCode,
                rhsModifiersRaw: continuousToggleModifiersRaw
            )
            let conflictsAssistantLiveVoice = shortcutsConflict(
                lhsKeyCode: normalizedCandidate.keyCode,
                lhsModifiersRaw: normalizedCandidate.modifiersRaw,
                rhsKeyCode: assistantLiveVoiceKeyCode,
                rhsModifiersRaw: assistantLiveVoiceModifiersRaw
            )
            let conflictsPasteLast = shortcutsConflict(
                lhsKeyCode: normalizedCandidate.keyCode,
                lhsModifiersRaw: normalizedCandidate.modifiersRaw,
                rhsKeyCode: PasteLastShortcut.keyCode,
                rhsModifiersRaw: PasteLastShortcut.modifiers
            )
            if !conflictsHold && !conflictsContinuous && !conflictsAssistantLiveVoice && !conflictsPasteLast {
                return normalizedCandidate
            }
        }

        return normalized
    }

}
