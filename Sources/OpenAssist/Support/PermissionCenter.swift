import AppKit
import AVFoundation
import CoreGraphics
import CoreServices
import Foundation
import Speech

enum PermissionCenter {
    struct AutomationTarget: Identifiable, Hashable, Sendable {
        let id: String
        let displayName: String
        let bundleIdentifiers: [String]

        fileprivate func resolvedBundleIdentifier() -> String? {
            bundleIdentifiers.first(where: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil })
        }
    }

    enum AutomationPermissionState: String, Sendable {
        case granted
        case notDetermined
        case denied
        case notInstalled
        case unavailable

        var displayLabel: String {
            switch self {
            case .granted:
                return "Allowed"
            case .notDetermined:
                return "Not Asked"
            case .denied:
                return "Denied"
            case .notInstalled:
                return "Not Installed"
            case .unavailable:
                return "Unavailable"
            }
        }
    }

    struct AutomationTargetStatus: Identifiable, Sendable {
        let target: AutomationTarget
        let resolvedBundleIdentifier: String?
        let state: AutomationPermissionState

        var id: String { target.id }
        var displayName: String { target.displayName }
        var isInstalled: Bool { resolvedBundleIdentifier != nil }
        var isGranted: Bool { state == .granted }
        var needsPrompt: Bool { state == .notDetermined }
        var needsManualEnableInSettings: Bool { state == .denied }
    }

    struct Snapshot: Sendable {
        let accessibilityGranted: Bool
        let microphoneGranted: Bool
        let speechRecognitionGranted: Bool
        let speechRecognitionRequired: Bool
        let screenRecordingGranted: Bool
        let appleEventsGranted: Bool
        let appleEventsKnown: Bool
        let fullDiskAccessGranted: Bool
        let fullDiskAccessKnown: Bool

        var allRequiredGranted: Bool {
            accessibilityGranted && microphoneGranted && (!speechRecognitionRequired || speechRecognitionGranted)
        }
    }

    static let commonAutomationTargets: [AutomationTarget] = [
        AutomationTarget(
            id: "finder",
            displayName: "Finder",
            bundleIdentifiers: ["com.apple.finder"]
        ),
        AutomationTarget(
            id: "terminal",
            displayName: "Terminal",
            bundleIdentifiers: ["com.apple.Terminal"]
        ),
        AutomationTarget(
            id: "system-events",
            displayName: "System Events",
            bundleIdentifiers: ["com.apple.systemevents"]
        ),
        AutomationTarget(
            id: "calendar",
            displayName: "Calendar",
            bundleIdentifiers: ["com.apple.iCal"]
        ),
        AutomationTarget(
            id: "reminders",
            displayName: "Reminders",
            bundleIdentifiers: ["com.apple.reminders"]
        ),
        AutomationTarget(
            id: "messages",
            displayName: "Messages",
            bundleIdentifiers: ["com.apple.MobileSMS"]
        ),
        AutomationTarget(
            id: "mail",
            displayName: "Mail",
            bundleIdentifiers: ["com.apple.mail"]
        ),
        AutomationTarget(
            id: "brave",
            displayName: "Brave Browser",
            bundleIdentifiers: ["com.brave.Browser"]
        ),
        AutomationTarget(
            id: "chrome",
            displayName: "Google Chrome",
            bundleIdentifiers: ["com.google.Chrome"]
        ),
        AutomationTarget(
            id: "edge",
            displayName: "Microsoft Edge",
            bundleIdentifiers: ["com.microsoft.edgemac"]
        ),
        AutomationTarget(
            id: "outlook",
            displayName: "Microsoft Outlook",
            bundleIdentifiers: ["com.microsoft.Outlook"]
        ),
        AutomationTarget(
            id: "teams",
            displayName: "Microsoft Teams",
            bundleIdentifiers: ["com.microsoft.teams2", "com.microsoft.teams"]
        ),
        AutomationTarget(
            id: "spotify",
            displayName: "Spotify",
            bundleIdentifiers: ["com.spotify.client"]
        )
    ]

    @MainActor
    static func snapshot(
        using settings: SettingsStore,
        includeExtendedPermissions: Bool = true
    ) -> Snapshot {
        snapshot(
            speechRecognitionRequired: settings.transcriptionEngine == .appleSpeech,
            includeExtendedPermissions: includeExtendedPermissions
        )
    }

    static func snapshot(
        speechRecognitionRequired: Bool,
        includeExtendedPermissions: Bool = true
    ) -> Snapshot {
        let accessibilityGranted = AXIsProcessTrusted()
        let appleEvents: (granted: Bool, known: Bool) = includeExtendedPermissions
            ? appleEventsPermissionProbe()
            : (granted: false, known: false)
        let fullDiskAccess: (granted: Bool, known: Bool) = includeExtendedPermissions
            ? fullDiskAccessProbe()
            : (granted: false, known: false)
        return Snapshot(
            accessibilityGranted: accessibilityGranted,
            microphoneGranted: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            speechRecognitionGranted: SFSpeechRecognizer.authorizationStatus() == .authorized,
            speechRecognitionRequired: speechRecognitionRequired,
            screenRecordingGranted: CGPreflightScreenCaptureAccess(),
            appleEventsGranted: appleEvents.granted,
            appleEventsKnown: appleEvents.known,
            fullDiskAccessGranted: fullDiskAccess.granted,
            fullDiskAccessKnown: fullDiskAccess.known
        )
    }

    @MainActor
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

    static func requestScreenRecordingPermission(openSettingsIfDenied: Bool = false) {
        if CGPreflightScreenCaptureAccess() { return }
        let granted = CGRequestScreenCaptureAccess()
        guard !granted, openSettingsIfDenied else { return }
        openPrivacySettingsPane(query: "Privacy_ScreenCapture")
    }

    static func requestAppleEventsPermission(openSettingsIfDenied: Bool = false) {
        let statuses = requestMissingAutomationPermissions()
        guard openSettingsIfDenied,
              statuses.contains(where: \.needsManualEnableInSettings) else { return }
        openPrivacySettingsPane(query: "Privacy_Automation")
    }

    static func automationPermissionStatuses() -> [AutomationTargetStatus] {
        commonAutomationTargets.map { automationPermissionStatus(for: $0) }
    }

    static func automationPermissionStatus(
        for target: AutomationTarget,
        promptIfNeeded: Bool = false
    ) -> AutomationTargetStatus {
        guard let resolvedBundleIdentifier = target.resolvedBundleIdentifier() else {
            return AutomationTargetStatus(
                target: target,
                resolvedBundleIdentifier: nil,
                state: .notInstalled
            )
        }

        let state = automationPermissionState(
            forBundleIdentifier: resolvedBundleIdentifier,
            promptIfNeeded: promptIfNeeded
        )
        return AutomationTargetStatus(
            target: target,
            resolvedBundleIdentifier: resolvedBundleIdentifier,
            state: state
        )
    }

    static func requestMissingAutomationPermissions() -> [AutomationTargetStatus] {
        commonAutomationTargets.map { target in
            let current = automationPermissionStatus(for: target)
            guard current.needsPrompt else {
                return current
            }
            return automationPermissionStatus(for: target, promptIfNeeded: true)
        }
    }

    static func requestAutomationPermission(
        forBundleIdentifier bundleIdentifier: String,
        displayName: String,
        openSettingsIfDenied: Bool = false
    ) -> AutomationTargetStatus {
        let target = AutomationTarget(
            id: bundleIdentifier,
            displayName: displayName,
            bundleIdentifiers: [bundleIdentifier]
        )
        let status = automationPermissionStatus(for: target, promptIfNeeded: true)
        guard openSettingsIfDenied, status.needsManualEnableInSettings else {
            return status
        }
        openPrivacySettingsPane(query: "Privacy_Automation")
        return status
    }

    static func openPrivacySettingsPane(query: String) {
        let openPane = {
            for url in privacySettingsURLs(query: query) {
                if NSWorkspace.shared.open(url) {
                    return
                }
            }

            let legacySecurityPaneURL = URL(fileURLWithPath: "/System/Library/PreferencePanes/Security.prefPane")
            _ = NSWorkspace.shared.open(legacySecurityPaneURL)
        }

        if Thread.isMainThread {
            openPane()
        } else {
            DispatchQueue.main.async(execute: openPane)
        }
    }

    static func openFullDiskAccessSettings() {
        openPrivacySettingsPane(query: "Privacy_AllFiles")
    }

    static func openScreenRecordingSettings() {
        openPrivacySettingsPane(query: "Privacy_ScreenCapture")
    }

    static func openAutomationSettings() {
        openPrivacySettingsPane(query: "Privacy_Automation")
    }

    nonisolated static func privacySettingsURLs(query: String) -> [URL] {
        [
            "x-apple.systempreferences:com.apple.preference.security?\(query)",
            "x-apple.systempreferences:com.apple.preference.security?Privacy",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
        ].compactMap(URL.init(string:))
    }

    private static func appleEventsPermissionProbe(promptIfNeeded: Bool = false) -> (granted: Bool, known: Bool) {
        // Use bundle identifier directly — Finder is always available, but we
        // don't need a running-application reference to build the AE target.
        let bundleIdentifier = "com.apple.finder"
        switch automationPermissionState(forBundleIdentifier: bundleIdentifier, promptIfNeeded: promptIfNeeded) {
        case .granted:
            return (true, true)
        case .notDetermined, .denied:
            return (false, true)
        case .notInstalled, .unavailable:
            return (false, false)
        }
    }

    private static func automationPermissionState(
        forBundleIdentifier bundleIdentifier: String,
        promptIfNeeded: Bool
    ) -> AutomationPermissionState {
        guard let identifierData = bundleIdentifier.data(using: .utf8), !identifierData.isEmpty else {
            return .unavailable
        }

        var target = AEAddressDesc()
        let createStatus = identifierData.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> OSErr in
            AECreateDesc(DescType(typeApplicationBundleID), bytes.baseAddress, identifierData.count, &target)
        }
        guard createStatus == noErr else {
            return .unavailable
        }
        defer { AEDisposeDesc(&target) }

        let status = AEDeterminePermissionToAutomateTarget(
            &target,
            AEEventClass(kCoreEventClass),
            AEEventID(kAEGetData),
            promptIfNeeded
        )

        switch status {
        case noErr:
            return .granted
        case OSStatus(errAEEventWouldRequireUserConsent):
            return .notDetermined
        case OSStatus(errAEEventNotPermitted):
            return .denied
        default:
            return .unavailable
        }
    }

    private static func fullDiskAccessProbe() -> (granted: Bool, known: Bool) {
        // Try directories in order — some may not exist if the user hasn't used
        // the corresponding app. ~/Library/Safari/Bookmarks.plist is the most
        // reliable single-file probe because Safari ships with every Mac.
        // We also try the TCC database itself as a fallback — it always exists
        // and is protected by Full Disk Access.
        let protectedPaths = [
            NSHomeDirectory() + "/Library/Safari",
            NSHomeDirectory() + "/Library/Mail",
            NSHomeDirectory() + "/Library/Messages",
            "/Library/Application Support/com.apple.TCC/TCC.db"
        ]

        for path in protectedPaths {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            guard exists else { continue }

            if isDirectory.boolValue {
                do {
                    _ = try FileManager.default.contentsOfDirectory(atPath: path)
                    return (true, true)
                } catch {
                    return (false, true)
                }
            } else {
                // It's a file — try to read a single byte.
                if FileManager.default.isReadableFile(atPath: path) {
                    return (true, true)
                } else {
                    return (false, true)
                }
            }
        }

        return (false, false)
    }
}
