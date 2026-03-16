import SwiftUI

struct AutomationAccessSettingsView: View {
    let onPermissionsChanged: () -> Void

    @State private var statuses: [PermissionCenter.AutomationTargetStatus] = []
    @State private var isRefreshing = false
    @State private var statusMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("macOS saves Automation access separately for each app. Example: allowing Terminal does not also allow Brave or Outlook.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if installedStatuses.isEmpty {
                Text("Open Assist could not find any supported automation targets on this Mac yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(installedStatuses) { status in
                        automationRow(for: status)
                    }
                }
            }

            HStack(spacing: 8) {
                Button("Grant Missing Access") {
                    requestMissingAccess()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRefreshing || missingPromptStatuses.isEmpty)

                Button("Refresh") {
                    refreshStatuses()
                }
                .buttonStyle(.bordered)
                .disabled(isRefreshing)

                Button("Open Automation Settings") {
                    PermissionCenter.openAutomationSettings()
                }
                .buttonStyle(.bordered)
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            refreshStatuses()
        }
    }

    private var installedStatuses: [PermissionCenter.AutomationTargetStatus] {
        statuses.filter(\.isInstalled)
    }

    private var missingPromptStatuses: [PermissionCenter.AutomationTargetStatus] {
        installedStatuses.filter(\.needsPrompt)
    }

    @ViewBuilder
    private func automationRow(for status: PermissionCenter.AutomationTargetStatus) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(status.displayName)
                    .font(.system(size: 13, weight: .semibold))

                if status.needsManualEnableInSettings {
                    Text("This app was denied earlier. Turn it on in System Settings > Privacy & Security > Automation.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 12)

            Text(status.state.displayLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(statusColor(for: status))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(statusColor(for: status).opacity(0.14), in: Capsule())

            if status.needsPrompt {
                Button("Allow") {
                    requestPermission(for: status.target)
                }
                .buttonStyle(.bordered)
                .disabled(isRefreshing)
            } else if status.needsManualEnableInSettings {
                Button("Review") {
                    PermissionCenter.openAutomationSettings()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func refreshStatuses() {
        isRefreshing = true
        statuses = PermissionCenter.automationPermissionStatuses()
        isRefreshing = false
        onPermissionsChanged()
    }

    private func requestMissingAccess() {
        isRefreshing = true
        statuses = PermissionCenter.requestMissingAutomationPermissions()
        isRefreshing = false
        onPermissionsChanged()

        if statuses.contains(where: \.needsManualEnableInSettings) {
            statusMessage = "Some apps still show Denied. If you clicked Don't Allow before, macOS will not ask again. Open Automation settings and turn them on there."
        } else if statuses.contains(where: \.needsPrompt) {
            statusMessage = "Some apps still need approval. macOS may still be waiting for your answer."
        } else {
            statusMessage = "Open Assist has asked for the installed app permissions it can request automatically."
        }
    }

    private func requestPermission(for target: PermissionCenter.AutomationTarget) {
        isRefreshing = true
        _ = PermissionCenter.automationPermissionStatus(for: target, promptIfNeeded: true)
        statuses = PermissionCenter.automationPermissionStatuses()
        isRefreshing = false
        onPermissionsChanged()

        if let refreshed = statuses.first(where: { $0.target.id == target.id }), refreshed.needsManualEnableInSettings {
            statusMessage = "\(refreshed.displayName) is still denied. Open Automation settings to turn it on manually."
        } else {
            statusMessage = nil
        }
    }

    private func statusColor(for status: PermissionCenter.AutomationTargetStatus) -> Color {
        switch status.state {
        case .granted:
            return .green
        case .notDetermined:
            return .orange
        case .denied:
            return .red
        case .notInstalled, .unavailable:
            return .secondary
        }
    }
}
