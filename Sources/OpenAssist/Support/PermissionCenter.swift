import AppKit
import AVFoundation
import CoreGraphics
import CoreServices
import Speech

@MainActor
enum PermissionCenter {
    struct Snapshot {
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

    static func snapshot(
        using settings: SettingsStore,
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
            speechRecognitionRequired: settings.transcriptionEngine == .appleSpeech,
            screenRecordingGranted: CGPreflightScreenCaptureAccess(),
            appleEventsGranted: appleEvents.granted,
            appleEventsKnown: appleEvents.known,
            fullDiskAccessGranted: fullDiskAccess.granted,
            fullDiskAccessKnown: fullDiskAccess.known
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

    static func requestScreenRecordingPermission(openSettingsIfDenied: Bool = false) {
        if CGPreflightScreenCaptureAccess() { return }
        let granted = CGRequestScreenCaptureAccess()
        guard !granted, openSettingsIfDenied else { return }
        openPrivacySettingsPane(query: "Privacy_ScreenCapture")
    }

    static func requestAppleEventsPermission(openSettingsIfDenied: Bool = false) {
        let probe = appleEventsPermissionProbe(promptIfNeeded: true)
        guard !probe.granted, openSettingsIfDenied else { return }
        openPrivacySettingsPane(query: "Privacy_Automation")
    }

    static func openPrivacySettingsPane(query: String) {
        for url in privacySettingsURLs(query: query) {
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
        guard let identifierData = bundleIdentifier.data(using: .utf8), !identifierData.isEmpty else {
            return (false, false)
        }

        var target = AEAddressDesc()
        let createStatus = identifierData.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> OSErr in
            AECreateDesc(DescType(typeApplicationBundleID), bytes.baseAddress, identifierData.count, &target)
        }
        guard createStatus == noErr else {
            return (false, false)
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
            return (true, true)
        case OSStatus(errAEEventNotPermitted), OSStatus(errAEEventWouldRequireUserConsent):
            return (false, true)
        default:
            return (false, false)
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
