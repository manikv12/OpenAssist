import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

struct RemoteAccessSettingsView: View {
    @ObservedObject var coordinator: RemoteAccessCoordinator

    private static let publicURLPlaceholder = "https://remote.yourdomain.com"

    @State private var portDraft = ""
    @State private var namedTunnelTokenDraft = ""
    @State private var namedTunnelNameDraft = ""
    @State private var namedTunnelPublicURLDraft = ""
    @State private var namedTunnelCredentialsFileDraft = ""
    @State private var cloudflaredPathDraft = ""
    @State private var adminPasswordDraft = ""
    @State private var adminPasswordConfirmationDraft = ""
    @State private var statusMessage: String?
    @State private var showPairingDetails = false
    @State private var showAdvancedCloudflare = false
    @State private var showAdvancedSettings = false
    @State private var showTechnicalStatus = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            quickStatusSection
            securitySection
            pairingSection
            publicAccessSection
            pairedDevicesSection
            advancedSection

            if let statusMessage,
               !statusMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: syncDrafts)
        .onChange(of: coordinator.remoteAccessPort) { portDraft = String($0) }
        .onChange(of: coordinator.namedTunnelName) { namedTunnelNameDraft = $0 }
        .onChange(of: coordinator.namedTunnelPublicURL) { namedTunnelPublicURLDraft = $0 }
        .onChange(of: coordinator.namedTunnelCredentialsFile) { namedTunnelCredentialsFileDraft = $0 }
        .onChange(of: coordinator.cloudflaredPathOverride) { cloudflaredPathDraft = $0 }
    }

    private var quickStatusSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Enable Remote Access", isOn: $coordinator.remoteAccessEnabled)
                    .font(.headline)

                statusPillRow

                HStack(spacing: 10) {
                    Button("Open Web UI") {
                        openURLString(preferredAccessURLString)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!coordinator.remoteAccessEnabled)

                    Button("Copy Link") {
                        copyToPasteboard(preferredAccessURLString)
                        statusMessage = "Remote Access link copied."
                    }
                    .buttonStyle(.bordered)
                    .disabled(!coordinator.remoteAccessEnabled)

                    Spacer()
                }

                Text(preferredAccessURLString)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } label: {
            Label("Remote Access", systemImage: "iphone.gen3.and.arrow.left.and.arrow.right")
                .font(.headline)
        }
    }

    private var statusPillRow: some View {
        HStack(spacing: 10) {
            Label(helperStatusLabel, systemImage: helperStatusSymbol)
                .font(.callout.weight(.medium))
                .foregroundStyle(helperStatusColor)

            if coordinator.tunnelMode != .disabled {
                Label(tunnelStatusLabel, systemImage: coordinator.tunnelStatus.isRunning ? "checkmark.icloud.fill" : "icloud.slash")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(coordinator.tunnelStatus.isRunning ? Color.green : Color.orange)
            }

            if !coordinator.pairedDevices.isEmpty {
                Label("\(coordinator.pairedDevices.count) paired", systemImage: "person.2.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Label(
                coordinator.adminPasswordConfigured ? "Password set" : "Set password",
                systemImage: coordinator.adminPasswordConfigured ? "lock.fill" : "lock.open.fill"
            )
            .font(.callout.weight(.medium))
            .foregroundStyle(coordinator.adminPasswordConfigured ? Color.green : Color.orange)

            Spacer()
        }
    }

    private var securitySection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Label(
                        coordinator.adminPasswordConfigured
                            ? "Remote password is set."
                            : "Set a remote password before sharing a public link.",
                        systemImage: coordinator.adminPasswordConfigured ? "lock.fill" : "exclamationmark.lock.fill"
                    )
                    .font(.callout.weight(.medium))
                    .foregroundStyle(coordinator.adminPasswordConfigured ? Color.green : Color.orange)

                    Spacer()

                    if coordinator.adminPasswordConfigured {
                        Button("Clear Password") {
                            coordinator.clearAdminPassword()
                            adminPasswordDraft = ""
                            adminPasswordConfirmationDraft = ""
                            statusMessage = "Remote Access password cleared."
                        }
                        .buttonStyle(.bordered)
                    }
                }

                Text("Browsers must enter this password before they can pair with this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    SecureField("New password", text: $adminPasswordDraft)
                        .textFieldStyle(.roundedBorder)

                    SecureField("Confirm password", text: $adminPasswordConfirmationDraft)
                        .textFieldStyle(.roundedBorder)

                    Button(coordinator.adminPasswordConfigured ? "Change" : "Set") {
                        saveAdminPassword()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        } label: {
            Label("Security", systemImage: "lock.shield")
                .font(.headline)
        }
    }

    private var publicAccessSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Choose how phones and other computers reach this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("Access", selection: $coordinator.tunnelModeRawValue) {
                    ForEach(RemoteTunnelMode.allCases) { mode in
                        Text(simpleTunnelModeName(mode)).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                if coordinator.tunnelMode == .disabled {
                    Text("Remote Access will only be available on this Mac.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if coordinator.tunnelMode == .named {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Custom domain")
                            .font(.callout.weight(.semibold))

                        HStack(spacing: 10) {
                            TextField(Self.publicURLPlaceholder, text: $namedTunnelPublicURLDraft)
                                .textFieldStyle(.roundedBorder)

                            Button("Save") {
                                saveNamedTunnelPublicURL()
                            }
                            .buttonStyle(.borderedProminent)
                        }

                        HStack(spacing: 10) {
                            Button("Copy Setup Commands") {
                                copyToPasteboard(cloudflareSetupCommands)
                                statusMessage = "Cloudflare setup commands copied."
                            }
                            .buttonStyle(.bordered)
                            .disabled(hostnameFromPublicURLDraft == nil)

                            if let publicURL = publicAccessURLString {
                                Button("Open Public URL") {
                                    openURLString(publicURL)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }

                if coordinator.tunnelMode == .quick {
                    Text("Open Assist will use a temporary Cloudflare URL.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if coordinator.tunnelMode != .disabled {
                    HStack(spacing: 10) {
                        Label(tunnelStatusLabel, systemImage: coordinator.tunnelStatus.isRunning ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(coordinator.tunnelStatus.isRunning ? Color.green : Color.orange)
                            .font(.callout.weight(.medium))

                        Spacer()
                    }

                    if let warning = coordinator.tunnelStatus.warning?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !warning.isEmpty {
                        Text(warning)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let publicURL = publicAccessURLString {
                        HStack(spacing: 10) {
                            Button("Copy Public Link") {
                                copyToPasteboard(publicURL)
                                statusMessage = "Public link copied."
                            }
                            .buttonStyle(.bordered)

                            Button("Open Public Link") {
                                openURLString(publicURL)
                            }
                            .buttonStyle(.bordered)
                        }

                        Text(publicURL)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                DisclosureGroup("Advanced Cloudflare settings", isExpanded: $showAdvancedCloudflare) {
                    VStack(alignment: .leading, spacing: 12) {
                        if coordinator.tunnelMode == .quick {
                            Picker("Transport", selection: $coordinator.tunnelTransportRawValue) {
                                ForEach(RemoteTunnelTransport.allCases) { transport in
                                    Text(transport.rawValue.uppercased()).tag(transport.rawValue)
                                }
                            }
                            .pickerStyle(.menu)
                        }

                        if coordinator.tunnelMode == .named {
                            namedTunnelAdvancedFields
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("cloudflared path")
                                .font(.callout.weight(.medium))

                            TextField("/opt/homebrew/bin/cloudflared", text: $cloudflaredPathDraft)
                                .textFieldStyle(.roundedBorder)

                            HStack(spacing: 10) {
                                Button("Save Path") {
                                    coordinator.cloudflaredPathOverride = cloudflaredPathDraft
                                    statusMessage = "cloudflared path saved."
                                }
                                .buttonStyle(.bordered)

                                Button("Use Homebrew Default") {
                                    cloudflaredPathDraft = "/opt/homebrew/bin/cloudflared"
                                    coordinator.cloudflaredPathOverride = cloudflaredPathDraft
                                    statusMessage = "Using /opt/homebrew/bin/cloudflared."
                                }
                                .buttonStyle(.bordered)
                            }
                        }

                        Text(cloudflareSetupCommands)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.secondary.opacity(0.08))
                            )

                        if let detail = coordinator.tunnelStatus.detail?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !detail.isEmpty {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        } label: {
            Label("Access From Away", systemImage: "network")
                .font(.headline)
        }
    }

    private var namedTunnelAdvancedFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Optional tunnel token")
                    .font(.callout.weight(.medium))

                SecureField("Paste a Cloudflare tunnel token, or leave blank", text: $namedTunnelTokenDraft)
                    .textFieldStyle(.roundedBorder)

                HStack(spacing: 10) {
                    Button("Save Token") {
                        coordinator.namedTunnelToken = namedTunnelTokenDraft
                        statusMessage = "Named tunnel token saved."
                    }
                    .buttonStyle(.bordered)

                    Button("Clear Token") {
                        namedTunnelTokenDraft = ""
                        coordinator.namedTunnelToken = ""
                        statusMessage = "Named tunnel token cleared."
                    }
                    .buttonStyle(.bordered)
                }

                Text(coordinator.maskedNamedTunnelToken)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Local named tunnel")
                    .font(.callout.weight(.medium))

                TextField(RemoteAccessCoordinator.defaultNamedTunnelName, text: $namedTunnelNameDraft)
                    .textFieldStyle(.roundedBorder)

                TextField("~/.cloudflared/<tunnel-id>.json", text: $namedTunnelCredentialsFileDraft)
                    .textFieldStyle(.roundedBorder)

                HStack(spacing: 10) {
                    Button("Save Local Tunnel") {
                        coordinator.namedTunnelName = namedTunnelNameDraft
                        coordinator.namedTunnelCredentialsFile = namedTunnelCredentialsFileDraft
                        statusMessage = "Local named tunnel saved."
                    }
                    .buttonStyle(.bordered)

                    Button("Use Default Name") {
                        namedTunnelNameDraft = RemoteAccessCoordinator.defaultNamedTunnelName
                        coordinator.namedTunnelName = namedTunnelNameDraft
                        statusMessage = "Default tunnel name set."
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var pairingSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Button(coordinator.activePairingChallenge == nil ? "Generate Pairing Code" : "Rotate Pairing Code") {
                        coordinator.rotatePairingChallenge()
                        statusMessage = "Pairing code generated."
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!coordinator.remoteAccessEnabled)

                    Button("Clear Code") {
                        coordinator.clearPairingChallenge()
                        statusMessage = "Pairing code cleared."
                    }
                    .buttonStyle(.bordered)
                    .disabled(coordinator.activePairingChallenge == nil)

                    Spacer()
                }

                if let challenge = coordinator.activePairingChallenge,
                   let pairingURL = coordinator.bestPairingURL()?.absoluteString {
                    Divider()

                    HStack(alignment: .top, spacing: 16) {
                        RemoteAccessQRCodeView(contents: pairingURL)
                            .frame(width: 168, height: 168)

                        VStack(alignment: .leading, spacing: 8) {
                            statusRow(title: "Code", value: challenge.code, monospaced: true)
                            statusRow(
                                title: "Expires",
                                value: challenge.expiresAt.formatted(
                                    date: .abbreviated,
                                    time: .shortened
                                )
                            )

                            HStack(spacing: 10) {
                                Button("Copy Pairing Link") {
                                    copyToPasteboard(pairingURL)
                                    statusMessage = "Pairing link copied."
                                }
                                .buttonStyle(.bordered)

                                Button("Open Pairing Link") {
                                    openURLString(pairingURL)
                                }
                                .buttonStyle(.bordered)
                            }

                            DisclosureGroup("Show full pairing link", isExpanded: $showPairingDetails) {
                                Text(pairingURL)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                } else {
                    Text("No active pairing code.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        } label: {
            Label("Connect a Device", systemImage: "qrcode")
                .font(.headline)
        }
    }

    private var pairedDevicesSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if coordinator.pairedDevices.isEmpty {
                    Text("No browsers or devices are paired yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(coordinator.pairedDevices) { device in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(device.name)
                                    .font(.callout.weight(.semibold))

                                Text("Added \(device.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                if let lastSeenAt = device.lastSeenAt {
                                    Text("Last seen \(lastSeenAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Spacer()

                            Button("Revoke") {
                                coordinator.revokeDevice(id: device.id)
                                statusMessage = "Revoked \(device.name)."
                            }
                            .buttonStyle(.bordered)
                        }

                        if device.id != coordinator.pairedDevices.last?.id {
                            Divider()
                        }
                    }
                }
            }
        } label: {
            Label("Paired Devices", systemImage: "desktopcomputer.and.iphone")
                .font(.headline)
        }
    }

    private var advancedSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                DisclosureGroup("Advanced helper settings", isExpanded: $showAdvancedSettings) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .center, spacing: 10) {
                            Text("Port")
                                .font(.callout.weight(.medium))

                            TextField("45832", text: $portDraft)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 120)

                            Button("Save Port") {
                                savePort()
                            }
                            .buttonStyle(.bordered)

                            Spacer()
                        }

                        statusRow(title: "Bind address", value: "127.0.0.1", monospaced: true)
                        statusRow(title: "Machine ID", value: coordinator.machineID, monospaced: true)
                        statusRow(title: "Local URL", value: localBaseURLString, monospaced: true)

                        Button("Copy Local URL") {
                            copyToPasteboard(localBaseURLString)
                            statusMessage = "Local helper URL copied."
                        }
                        .buttonStyle(.bordered)
                    }
                }

                DisclosureGroup("Technical status", isExpanded: $showTechnicalStatus) {
                    VStack(alignment: .leading, spacing: 8) {
                        statusRow(title: "Helper state", value: coordinator.helperState)
                        statusRow(
                            title: "Tunnel",
                            value: coordinator.tunnelStatus.isRunning ? "Running" : coordinator.tunnelStatus.mode.displayName
                        )
                        statusRow(title: "Paired devices", value: "\(coordinator.pairedDevices.count)")
                        if let snapshot = coordinator.currentSnapshot {
                            statusRow(title: "Known sessions", value: "\(snapshot.sessions.count)")
                        }
                        if let executablePath = coordinator.tunnelStatus.executablePath?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !executablePath.isEmpty {
                            statusRow(title: "Executable", value: executablePath, monospaced: true)
                        }
                        if let helperMessage = coordinator.helperMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !helperMessage.isEmpty {
                            Text(helperMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        } label: {
            Label("Advanced", systemImage: "slider.horizontal.3")
                .font(.headline)
        }
    }

    private var localBaseURLString: String {
        "http://127.0.0.1:\(coordinator.remoteAccessPort)"
    }

    private var preferredAccessURLString: String {
        publicAccessURLString ?? localBaseURLString
    }

    private var publicAccessURLString: String? {
        if let publicURL = coordinator.tunnelStatus.publicURL?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            return publicURL
        }
        if coordinator.tunnelMode == .named,
           let publicURL = coordinator.namedTunnelPublicURL.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            return publicURL
        }
        return nil
    }

    private var helperStatusLabel: String {
        guard coordinator.remoteAccessEnabled else { return "Off" }
        let state = coordinator.helperState.trimmingCharacters(in: .whitespacesAndNewlines)
        return state.isEmpty ? "Starting" : state
    }

    private var helperStatusSymbol: String {
        if !coordinator.remoteAccessEnabled {
            return "power"
        }
        return coordinator.helperState.caseInsensitiveCompare("Running") == .orderedSame
            ? "checkmark.circle.fill"
            : "clock.fill"
    }

    private var helperStatusColor: Color {
        if !coordinator.remoteAccessEnabled {
            return .secondary
        }
        return coordinator.helperState.caseInsensitiveCompare("Running") == .orderedSame
            ? .green
            : .orange
    }

    private var tunnelStatusLabel: String {
        guard coordinator.tunnelMode != .disabled else { return "Tunnel off" }
        if coordinator.tunnelStatus.isRunning {
            return "Public link running"
        }
        if !coordinator.tunnelStatus.configured {
            return "Needs setup"
        }
        return "Starting public link"
    }

    private func simpleTunnelModeName(_ mode: RemoteTunnelMode) -> String {
        switch mode {
        case .disabled:
            return "Local"
        case .quick:
            return "Temporary"
        case .named:
            return "Custom Domain"
        }
    }

    private var cloudflareSetupCommands: String {
        let tunnelName = namedTunnelNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? RemoteAccessCoordinator.defaultNamedTunnelName
        let hostname = hostnameFromPublicURLDraft
            ?? "remote.yourdomain.com"
        return """
        cloudflared tunnel create \(tunnelName)
        cloudflared tunnel route dns \(tunnelName) \(hostname)
        """
    }

    private var hostnameFromPublicURLDraft: String? {
        let trimmed = namedTunnelPublicURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let valueWithScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        return URLComponents(string: valueWithScheme)?.host?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    private func savePort() {
        let trimmed = portDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = UInt16(trimmed), value >= 1024 else {
            statusMessage = "Enter a port between 1024 and \(UInt16.max)."
            portDraft = String(coordinator.remoteAccessPort)
            return
        }
        coordinator.remoteAccessPort = value
        portDraft = String(coordinator.remoteAccessPort)
        statusMessage = "Remote helper port saved."
    }

    private func saveNamedTunnelPublicURL() {
        let trimmed = namedTunnelPublicURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            coordinator.namedTunnelPublicURL = ""
            namedTunnelPublicURLDraft = ""
            statusMessage = "Public URL cleared. Named local tunnel needs your Cloudflare hostname before it can start."
            return
        }

        let valueWithScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: valueWithScheme),
              components.scheme == "https" || components.scheme == "http",
              components.host?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty != nil else {
            statusMessage = "Enter a valid URL, like https://remote.yourdomain.com."
            return
        }

        coordinator.namedTunnelPublicURL = valueWithScheme
        namedTunnelPublicURLDraft = valueWithScheme
        statusMessage = "Named tunnel URL saved."
    }

    private func saveAdminPassword() {
        let password = adminPasswordDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let confirmation = adminPasswordConfirmationDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard password.count >= 8 else {
            statusMessage = "Use at least 8 characters for the Remote Access password."
            return
        }
        guard password == confirmation else {
            statusMessage = "The Remote Access passwords do not match."
            return
        }
        guard coordinator.setAdminPassword(password) else {
            statusMessage = "Could not save the Remote Access password."
            return
        }
        adminPasswordDraft = ""
        adminPasswordConfirmationDraft = ""
        statusMessage = "Remote Access password saved."
    }

    private func statusRow(title: String, value: String, monospaced: Bool = false) -> some View {
        LabeledContent(title) {
            Text(value)
                .font(monospaced ? .system(.caption, design: .monospaced) : .callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func syncDrafts() {
        portDraft = String(coordinator.remoteAccessPort)
        namedTunnelTokenDraft = coordinator.namedTunnelToken
        namedTunnelNameDraft = coordinator.namedTunnelName
        namedTunnelPublicURLDraft = coordinator.namedTunnelPublicURL
        namedTunnelCredentialsFileDraft = coordinator.namedTunnelCredentialsFile
        cloudflaredPathDraft = coordinator.cloudflaredPathOverride
        adminPasswordDraft = ""
        adminPasswordConfirmationDraft = ""
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func openURLString(_ value: String) {
        guard let url = URL(string: value) else {
            statusMessage = "That URL is not valid."
            return
        }
        NSWorkspace.shared.open(url)
    }
}

private struct RemoteAccessQRCodeView: View {
    let contents: String

    private let context = CIContext()
    private let filter = CIFilter.qrCodeGenerator()

    var body: some View {
        Group {
            if let image = makeImage(from: contents) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(0.12))
                    .overlay(
                        Image(systemName: "qrcode")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    )
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white)
        )
    }

    private func makeImage(from value: String) -> NSImage? {
        let data = Data(value.utf8)
        filter.message = data
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage?
            .transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
            let cgImage = context.createCGImage(outputImage, from: outputImage.extent) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: outputImage.extent.width, height: outputImage.extent.height))
    }
}
