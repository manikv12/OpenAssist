import SwiftUI

struct BrowserAutomationSettingsView: View {
    @ObservedObject var settings: SettingsStore
    @State private var profiles: [BrowserProfile] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Browser Automation")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Toggle("", isOn: $settings.browserAutomationEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
            }

            if settings.browserAutomationEnabled {
                Divider()
                browserProfilePicker
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .onAppear {
            refreshProfiles()
        }
        .onChange(of: settings.browserAutomationEnabled) { _ in
            refreshProfiles()
        }
    }

    @ViewBuilder
    private var browserProfilePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Browser Profile")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)

            Text("Select which browser and profile to use. The assistant will have access to your existing logins and sessions.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if profiles.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12))
                    Text("No browser profiles found.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            } else {
                Picker("", selection: $settings.browserSelectedProfileID) {
                    Text("Select a profile...")
                        .tag("")
                    ForEach(groupedProfiles, id: \.browser) { group in
                        Section(group.browser.displayName) {
                            ForEach(group.profiles) { profile in
                                Text(profile.label)
                                    .tag(profile.id)
                            }
                        }
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()

                if let selected = selectedProfile {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.blue)
                            .font(.system(size: 11))
                        Text("Using \(selected.browser.displayName) with profile \"\(selected.displayName)\"")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Spacer()
                Button {
                    refreshProfiles()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Refresh browser profiles")
            }
        }
    }

    private var selectedProfile: BrowserProfile? {
        profiles.first { $0.id == settings.browserSelectedProfileID }
    }

    private struct BrowserGroup {
        let browser: SupportedBrowser
        let profiles: [BrowserProfile]
    }

    private var groupedProfiles: [BrowserGroup] {
        let manager = BrowserProfileManager.shared
        return manager.installedBrowsers().compactMap { browser in
            let browserProfiles = profiles.filter { $0.browser == browser }
            guard !browserProfiles.isEmpty else { return nil }
            return BrowserGroup(browser: browser, profiles: browserProfiles)
        }
    }

    private func refreshProfiles() {
        Task.detached {
            let loaded = BrowserProfileManager.shared.allProfiles()
            await MainActor.run { profiles = loaded }
        }
    }
}
