import SwiftUI

/// A sheet presented when the assistant needs browser access but no profile is configured.
struct BrowserProfilePickerSheet: View {
    let onSelect: (BrowserProfile) -> Void
    let onCancel: () -> Void

    @State private var profiles: [BrowserProfile] = []
    @State private var selectedID: String = ""

    var body: some View {
        VStack(spacing: 16) {
            // Header
            VStack(spacing: 6) {
                Image(systemName: "globe")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.blue)

                Text("Browser Profile Required")
                    .font(.system(size: 15, weight: .semibold))

                Text("The assistant needs to use a browser. Select which browser and profile to use.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            if profiles.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 20))
                        .foregroundStyle(.orange)
                    Text("No browser profiles found on this Mac.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("Install Chrome or Brave and create a profile first.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(profiles) { profile in
                        ProfileRow(
                            profile: profile,
                            isSelected: selectedID == profile.id
                        )
                        .onTapGesture {
                            selectedID = profile.id
                        }
                    }
                }
                .frame(maxHeight: 200)
            }

            Divider()

            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button("Use This Profile") {
                    if let profile = profiles.first(where: { $0.id == selectedID }) {
                        onSelect(profile)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(selectedID.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .task {
            let loaded = await Task.detached {
                BrowserProfileManager.shared.allProfiles()
            }.value
            profiles = loaded
            if loaded.count == 1 {
                selectedID = loaded[0].id
            }
        }
    }
}

private struct ProfileRow: View {
    let profile: BrowserProfile
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: profile.browser == .chrome ? "network" : "shield.lefthalf.filled")
                .font(.system(size: 14))
                .foregroundStyle(isSelected ? .white : .secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(profile.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSelected ? .white : .primary)
                Text(profile.browser.displayName)
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? .white.opacity(0.7) : .secondary)
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.white)
                    .font(.system(size: 14))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
        .contentShape(Rectangle())
    }
}
