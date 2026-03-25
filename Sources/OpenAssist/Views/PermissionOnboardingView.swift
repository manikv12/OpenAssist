import AppKit
import SwiftUI

struct PermissionOnboardingView: View {
    @EnvironmentObject private var settings: SettingsStore
    let onComplete: () -> Void

    @State private var accessibilityGranted = false
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

    private var continueButtonTitle: String {
        allRequiredGranted ? "Continue to Getting Started" : "Continue"
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
                        title: "Automation / Apple Events",
                        hint: appleEventsKnown
                            ? "Optional for browser reuse and direct app automation. Click Grant to ask for each installed target app one by one."
                            : "Optional for browser reuse and direct app automation. Click Grant to ask for each installed target app one by one.",
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

                VStack(alignment: .leading, spacing: 10) {
                    Text("Next after permissions")
                        .font(.callout.weight(.semibold))

                    Text("Open Assist will send you to one simple setup home next. From there you can connect the assistant, test voice dictation, and optionally set up browser or app control.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 8) {
                        nextStepRow(
                            title: "Connect assistant or provider",
                            detail: "Pick the AI setup you want without hunting through several windows."
                        )
                        nextStepRow(
                            title: "Try voice dictation",
                            detail: "Check your microphone, shortcut, and speech settings in one place."
                        )
                        nextStepRow(
                            title: "Optional browser and app control",
                            detail: "Only set this up if you want automation features like browser reuse or Computer Use."
                        )
                    }
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

                    Button(continueButtonTitle) {
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
            .frame(width: 680, alignment: .topLeading)
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
            AppIconBadge(
                symbol: granted ? "checkmark.shield.fill" : "hand.raised.slash.fill",
                tint: granted ? .green : AppVisualTheme.baseTint,
                size: 28,
                symbolSize: 12,
                isEmphasized: granted
            )

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

            PermissionStateBadge(
                granted: granted,
                grantedLabel: "Allowed",
                missingLabel: required ? "Required" : "Optional"
            )

            if !granted {
                Button("Grant") {
                    action()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func nextStepRow(title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.turn.down.right")
                .foregroundStyle(AppVisualTheme.accentTint)
                .font(.system(size: 11, weight: .semibold))
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func refreshPermissionSnapshot() {
        let snapshot = PermissionCenter.snapshot(using: settings)
        accessibilityGranted = snapshot.accessibilityGranted
        microphoneGranted = snapshot.microphoneGranted
        speechRecognitionGranted = snapshot.speechRecognitionGranted
        speechRecognitionRequired = snapshot.speechRecognitionRequired
        appleEventsGranted = snapshot.appleEventsGranted
        appleEventsKnown = snapshot.appleEventsKnown
        fullDiskAccessGranted = snapshot.fullDiskAccessGranted
        fullDiskAccessKnown = snapshot.fullDiskAccessKnown
    }
}
