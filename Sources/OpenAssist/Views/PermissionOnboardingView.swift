import AppKit
import SwiftUI

struct PermissionOnboardingView: View {
    @EnvironmentObject private var settings: SettingsStore
    let onComplete: () -> Void

    @State private var accessibilityGranted = false
    @State private var screenRecordingGranted = false
    @State private var microphoneGranted = false
    @State private var speechRecognitionGranted = false
    @State private var speechRecognitionRequired = true
    @State private var appleEventsGranted = false
    @State private var appleEventsKnown = false
    @State private var fullDiskAccessGranted = false
    @State private var fullDiskAccessKnown = false

    private var allRequiredGranted: Bool {
        accessibilityGranted && microphoneGranted && (!speechRecognitionRequired || speechRecognitionGranted)
    }

    var body: some View {
        ZStack {
            AppChromeBackground()

            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    if let icon = NSApplication.shared.applicationIconImage {
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Finish Permission Setup")
                            .font(.title2.weight(.semibold))
                        Text("Open Assist needs these permissions before assistant voice capture, dictation, and global shortcuts can run.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    permissionRow(
                            title: "Accessibility",
                            hint: "Required for global hotkeys and text insertion across apps.",
                            granted: accessibilityGranted,
                            required: true,
                            action: {
                            PermissionCenter.requestAccessibilityPermission(
                                using: settings,
                                promptIfNeeded: true,
                                openSettingsIfDenied: false
                            )
                            refreshPermissionSnapshot()
                        }
                    )

                    permissionRow(
                        title: "Microphone",
                        hint: "Required to capture speech.",
                        granted: microphoneGranted,
                        required: true,
                        action: {
                            PermissionCenter.requestMicrophonePermission(openSettingsIfDenied: true)
                            refreshPermissionSnapshot()
                        }
                    )

                    permissionRow(
                        title: "Speech Recognition",
                        hint: speechRecognitionRequired
                            ? "Required while Apple Speech is selected."
                            : "Optional while whisper.cpp is selected.",
                        granted: speechRecognitionGranted,
                        required: speechRecognitionRequired,
                        action: {
                            PermissionCenter.requestSpeechRecognitionPermission(openSettingsIfDenied: true)
                            refreshPermissionSnapshot()
                        }
                    )

                    Divider()

                    permissionRow(
                        title: "Screen Recording",
                        hint: "Optional for computer control. Needed when Open Assist must understand what is visible on your screen.",
                        granted: screenRecordingGranted,
                        required: false,
                        action: {
                            PermissionCenter.requestScreenRecordingPermission(openSettingsIfDenied: true)
                            refreshPermissionSnapshot()
                        }
                    )

                    permissionRow(
                        title: "Automation / Apple Events",
                        hint: appleEventsKnown
                            ? "Optional for computer control. Click Grant to ask for each installed target app one by one."
                            : "Optional for computer control. Click Grant to ask for each installed target app one by one.",
                        granted: appleEventsGranted,
                        required: false,
                        action: {
                            PermissionCenter.requestAppleEventsPermission(openSettingsIfDenied: true)
                            refreshPermissionSnapshot()
                        }
                    )

                    permissionRow(
                        title: "Full Disk Access",
                        hint: fullDiskAccessKnown
                            ? "Optional. Only needed for protected app data and folders."
                            : "Optional. Only open this if a protected location needs it later.",
                        granted: fullDiskAccessGranted,
                        required: false,
                        action: {
                            PermissionCenter.openPrivacySettingsPane(query: "Full Disk Access")
                            refreshPermissionSnapshot()
                        }
                    )
                }
                .padding(12)
                .appThemedSurface(cornerRadius: 12, strokeOpacity: 0.17)

                if !allRequiredGranted {
                    Text("Open Assist stays paused until required permissions are granted.")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.orange)
                }

                HStack(spacing: 10) {
                    Button("Check Again") {
                        refreshPermissionSnapshot()
                    }
                    .buttonStyle(.bordered)

                    Button("Open Privacy Settings") {
                        PermissionCenter.openPrivacySettingsPane(query: "Privacy")
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button("Continue") {
                        refreshPermissionSnapshot()
                        guard allRequiredGranted else { return }
                        onComplete()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!allRequiredGranted)
                }
            }
            .padding(22)
            .appThemedSurface(cornerRadius: 16, strokeOpacity: 0.18)
            .shadow(color: .black.opacity(0.16), radius: 18, x: 0, y: 10)
            .frame(width: 620, height: 560, alignment: .topLeading)
            .padding(18)
        }
        .onAppear {
            refreshPermissionSnapshot()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissionSnapshot()
        }
        .onReceive(
            Timer.publish(every: 0.9, on: .main, in: .common).autoconnect()
        ) { _ in
            if !allRequiredGranted {
                refreshPermissionSnapshot()
            }
        }
        .tint(AppVisualTheme.accentTint)
    }

    @ViewBuilder
    private func permissionRow(
        title: String,
        hint: String,
        granted: Bool,
        required: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? .green : .orange)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                    if !required {
                        Text("Optional")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if granted {
                Text("Granted")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            } else {
                Button("Grant") {
                    action()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private func refreshPermissionSnapshot() {
        let snapshot = PermissionCenter.snapshot(using: settings)
        accessibilityGranted = snapshot.accessibilityGranted
        screenRecordingGranted = snapshot.screenRecordingGranted
        microphoneGranted = snapshot.microphoneGranted
        speechRecognitionGranted = snapshot.speechRecognitionGranted
        speechRecognitionRequired = snapshot.speechRecognitionRequired
        appleEventsGranted = snapshot.appleEventsGranted
        appleEventsKnown = snapshot.appleEventsKnown
        fullDiskAccessGranted = snapshot.fullDiskAccessGranted
        fullDiskAccessKnown = snapshot.fullDiskAccessKnown
    }
}
