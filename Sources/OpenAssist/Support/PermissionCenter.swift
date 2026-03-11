import AppKit
import AVFoundation
import Speech

@MainActor
enum PermissionCenter {
    struct Snapshot {
        let accessibilityGranted: Bool
        let microphoneGranted: Bool
        let speechRecognitionGranted: Bool
        let speechRecognitionRequired: Bool

        var allRequiredGranted: Bool {
            accessibilityGranted && microphoneGranted && (!speechRecognitionRequired || speechRecognitionGranted)
        }
    }

    static func snapshot(using settings: SettingsStore) -> Snapshot {
        settings.refreshAccessibilityStatus(prompt: false)
        return Snapshot(
            accessibilityGranted: settings.accessibilityTrusted,
            microphoneGranted: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            speechRecognitionGranted: SFSpeechRecognizer.authorizationStatus() == .authorized,
            speechRecognitionRequired: settings.transcriptionEngine == .appleSpeech
        )
    }

    static func requestAccessibilityPermission(
        using settings: SettingsStore,
        promptIfNeeded: Bool = true,
        openSettingsIfDenied: Bool = true
    ) {
        settings.refreshAccessibilityStatus(prompt: promptIfNeeded)
        if !settings.accessibilityTrusted, openSettingsIfDenied {
            openPrivacySettingsPane(query: "Privacy_Accessibility")
        }
    }

    static func requestMicrophonePermission(openSettingsIfDenied: Bool = false) {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .authorized { return }

        // Always attempt requestAccess — on a fresh install or after tccutil reset
        // the status may be .notDetermined or even .denied before the app has ever
        // triggered the system prompt with the current code signature.
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            guard !granted, openSettingsIfDenied else { return }
            DispatchQueue.main.async { openPrivacySettingsPane(query: "Privacy_Microphone") }
        }
    }

    static func requestSpeechRecognitionPermission(openSettingsIfDenied: Bool = false) {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { status in
                guard status != .authorized, openSettingsIfDenied else { return }
                DispatchQueue.main.async { openPrivacySettingsPane(query: "Privacy_SpeechRecognition") }
            }
        case .denied, .restricted:
            if openSettingsIfDenied {
                openPrivacySettingsPane(query: "Privacy_SpeechRecognition")
            }
        @unknown default:
            if openSettingsIfDenied {
                openPrivacySettingsPane(query: "Privacy_SpeechRecognition")
            }
        }
    }

    static func openPrivacySettingsPane(query: String) {
        let urlStrings = [
            "x-apple.systempreferences:com.apple.preference.security?\(query)",
            "x-apple.systempreferences:com.apple.preference.security?Privacy",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
        ]

        for urlString in urlStrings {
            guard let url = URL(string: urlString) else { continue }
            if NSWorkspace.shared.open(url) {
                return
            }
        }

        let legacySecurityPaneURL = URL(fileURLWithPath: "/System/Library/PreferencePanes/Security.prefPane")
        _ = NSWorkspace.shared.open(legacySecurityPaneURL)
    }

    static func openFullDiskAccessSettings() {
        openPrivacySettingsPane(query: "Privacy_AllFiles")
    }

    static func openAutomationSettings() {
        openPrivacySettingsPane(query: "Privacy_Automation")
    }
}
