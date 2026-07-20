import Foundation

struct RemoteTunnelConfiguration: Equatable, Sendable {
    let mode: RemoteTunnelMode
    let transport: RemoteTunnelTransport
    let localPort: UInt16
    let manualExecutablePath: String
    let namedTunnelToken: String
    let namedTunnelName: String
    let namedTunnelPublicURL: String
    let namedTunnelCredentialsFile: String
}

protocol RemoteTunnelProvider: AnyObject {
    var onStatusChange: (@Sendable (RemoteAccessTunnelStatus) -> Void)? { get set }
    func apply(configuration: RemoteTunnelConfiguration)
    func stop()
}

final class CloudflaredTunnelProvider: RemoteTunnelProvider {
    var onStatusChange: (@Sendable (RemoteAccessTunnelStatus) -> Void)?

    private let callbackQueue = DispatchQueue(label: "OpenAssist.RemoteTunnel.Callbacks")
    private var process: Process?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private var metricsURL: URL?
    private var currentConfiguration = RemoteTunnelConfiguration(
        mode: .disabled,
        transport: .auto,
        localPort: 0,
        manualExecutablePath: "",
        namedTunnelToken: "",
        namedTunnelName: "",
        namedTunnelPublicURL: "",
        namedTunnelCredentialsFile: ""
    )
    private var currentStatus = RemoteAccessTunnelStatus(
        mode: .disabled,
        transport: .auto,
        configured: false,
        isRunning: false,
        publicURL: nil,
        warning: nil,
        detail: "Tunnel disabled.",
        executablePath: nil
    )

    deinit {
        stop()
    }

    func apply(configuration: RemoteTunnelConfiguration) {
        currentConfiguration = configuration
        stop()

        guard configuration.mode != .disabled else {
            emitStatus(
                RemoteAccessTunnelStatus(
                    mode: configuration.mode,
                    transport: configuration.transport,
                    configured: false,
                    isRunning: false,
                    publicURL: nil,
                    warning: nil,
                    detail: "Tunnel disabled.",
                    executablePath: nil
                )
            )
            return
        }

        let resolvedPath = Self.resolveExecutablePath(manualOverride: configuration.manualExecutablePath)
        guard let executablePath = resolvedPath else {
            emitStatus(
                RemoteAccessTunnelStatus(
                    mode: configuration.mode,
                    transport: configuration.transport,
                    configured: true,
                    isRunning: false,
                    publicURL: nil,
                    warning: nil,
                    detail: "cloudflared was not found. Install it or set a manual path.",
                    executablePath: configuration.manualExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                )
            )
            return
        }

        let launchConfiguration = Self.configurationWithDiscoveredCredentials(
            configuration,
            cloudflaredPath: executablePath
        )
        currentConfiguration = launchConfiguration

        let launchArguments: [String]
        do {
            launchArguments = try Self.launchArguments(for: launchConfiguration)
        } catch {
            emitStatus(
                RemoteAccessTunnelStatus(
                    mode: launchConfiguration.mode,
                    transport: launchConfiguration.transport,
                    configured: true,
                    isRunning: false,
                    publicURL: nil,
                    warning: nil,
                    detail: error.localizedDescription,
                    executablePath: executablePath
                )
            )
            return
        }

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = launchArguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.terminationHandler = { [weak self] terminated in
            guard let self else { return }
            self.callbackQueue.async {
                self.process = nil
                self.outputHandle?.readabilityHandler = nil
                self.errorHandle?.readabilityHandler = nil
                self.outputHandle = nil
                self.errorHandle = nil
                self.metricsURL = nil

                let detail: String
                if terminated.terminationReason == .exit, terminated.terminationStatus == 0 {
                    detail = "Tunnel stopped."
                } else {
                    detail = "cloudflared stopped with exit code \(terminated.terminationStatus)."
                }

                self.emitStatus(
                    RemoteAccessTunnelStatus(
                        mode: self.currentConfiguration.mode,
                        transport: self.currentConfiguration.transport,
                        configured: true,
                        isRunning: false,
                        publicURL: self.currentStatus.publicURL,
                        warning: self.currentStatus.warning,
                        detail: detail,
                        executablePath: executablePath
                    )
                )
            }
        }

        do {
            try process.run()
            self.process = process
            self.outputHandle = outputPipe.fileHandleForReading
            self.errorHandle = errorPipe.fileHandleForReading
            installReadabilityHandlers(
                outputHandle: outputPipe.fileHandleForReading,
                errorHandle: errorPipe.fileHandleForReading,
                executablePath: executablePath
            )

            emitStatus(
                RemoteAccessTunnelStatus(
                    mode: launchConfiguration.mode,
                    transport: launchConfiguration.transport,
                    configured: true,
                    isRunning: true,
                    publicURL: launchConfiguration.mode == .named
                        ? launchConfiguration.namedTunnelPublicURL.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                        : nil,
                    warning: launchConfiguration.mode == .quick
                        ? "Quick Tunnel URLs change whenever the tunnel restarts."
                        : nil,
                    detail: launchConfiguration.mode == .quick
                        ? "Starting Quick Tunnel..."
                        : "Starting named tunnel...",
                    executablePath: executablePath
                )
            )
        } catch {
            emitStatus(
                RemoteAccessTunnelStatus(
                    mode: launchConfiguration.mode,
                    transport: launchConfiguration.transport,
                    configured: true,
                    isRunning: false,
                    publicURL: nil,
                    warning: nil,
                    detail: error.localizedDescription,
                    executablePath: executablePath
                )
            )
        }
    }

    func stop() {
        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        outputHandle = nil
        errorHandle = nil
        metricsURL = nil

        guard let process else { return }
        if process.isRunning {
            process.terminate()
        }
        self.process = nil
    }

    private func installReadabilityHandlers(
        outputHandle: FileHandle,
        errorHandle: FileHandle,
        executablePath: String
    ) {
        let lineHandler: (Data) -> Void = { [weak self] data in
            guard let self, let line = String(data: data, encoding: .utf8), !line.isEmpty else {
                return
            }
            self.handleLogLine(line, executablePath: executablePath)
        }

        outputHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            lineHandler(data)
        }
        errorHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            lineHandler(data)
        }
    }

    private func handleLogLine(_ rawLine: String, executablePath: String) {
        let lines = rawLine
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for line in lines {
            if let url = Self.extractQuickTunnelURL(from: line) {
                emitStatus(
                    RemoteAccessTunnelStatus(
                        mode: currentConfiguration.mode,
                        transport: currentConfiguration.transport,
                        configured: true,
                        isRunning: true,
                        publicURL: url.absoluteString,
                        warning: currentConfiguration.mode == .quick
                            ? "Quick Tunnel URLs change whenever the tunnel restarts."
                            : nil,
                        detail: "Tunnel connected.",
                        executablePath: executablePath
                    )
                )
                continue
            }

            if let metricsURL = Self.extractMetricsURL(from: line) {
                self.metricsURL = metricsURL
                Task { [weak self] in
                    guard let self,
                          self.currentConfiguration.mode == .quick,
                          self.currentStatus.publicURL == nil else {
                        return
                    }
                    if let fetched = await Self.fetchQuickTunnelURL(fromMetricsURL: metricsURL) {
                        self.emitStatus(
                            RemoteAccessTunnelStatus(
                                mode: self.currentConfiguration.mode,
                                transport: self.currentConfiguration.transport,
                                configured: true,
                                isRunning: true,
                                publicURL: fetched.absoluteString,
                                warning: "Quick Tunnel URLs change whenever the tunnel restarts.",
                                detail: "Tunnel connected.",
                                executablePath: executablePath
                            )
                        )
                    }
                }
                continue
            }

            if line.localizedCaseInsensitiveContains("error") {
                emitStatus(
                    RemoteAccessTunnelStatus(
                        mode: currentConfiguration.mode,
                        transport: currentConfiguration.transport,
                        configured: true,
                        isRunning: process?.isRunning == true,
                        publicURL: currentStatus.publicURL,
                        warning: currentStatus.warning,
                        detail: line,
                        executablePath: executablePath
                    )
                )
                continue
            }

            if currentStatus.detail?.contains("Starting") == true {
                emitStatus(
                    RemoteAccessTunnelStatus(
                        mode: currentConfiguration.mode,
                        transport: currentConfiguration.transport,
                        configured: true,
                        isRunning: process?.isRunning == true,
                        publicURL: currentStatus.publicURL,
                        warning: currentStatus.warning,
                        detail: line,
                        executablePath: executablePath
                    )
                )
            }
        }
    }

    private func emitStatus(_ status: RemoteAccessTunnelStatus) {
        currentStatus = status
        onStatusChange?(status)
    }

    static func arguments(for configuration: RemoteTunnelConfiguration) -> [String] {
        (try? launchArguments(for: configuration)) ?? []
    }

    static func launchArguments(
        for configuration: RemoteTunnelConfiguration,
        localNamedTunnelConfigPath: String? = nil
    ) throws -> [String] {
        let localURL = "http://127.0.0.1:\(configuration.localPort)"
        switch configuration.mode {
        case .disabled:
            return []
        case .quick:
            return [
                "tunnel",
                "--protocol",
                configuration.transport.rawValue,
                "--url",
                localURL
            ]
        case .named:
            let token = configuration.namedTunnelToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty {
                return [
                    "tunnel",
                    "--no-autoupdate",
                    "run",
                    "--token",
                    token
                ]
            }

            let tunnelName = configuration.normalizedNamedTunnelName
            guard !tunnelName.isEmpty else {
                throw RemoteTunnelProviderError.missingNamedTunnelName
            }
            let configURL = try localNamedTunnelConfigPath
                .map { URL(fileURLWithPath: $0) }
                ?? writeLocalNamedTunnelConfig(for: configuration)
            return [
                "tunnel",
                "--config",
                configURL.path,
                "--no-autoupdate",
                "run",
                tunnelName
            ]
        }
    }

    static func localNamedTunnelConfigText(for configuration: RemoteTunnelConfiguration) throws -> String {
        let tunnelName = configuration.normalizedNamedTunnelName
        guard !tunnelName.isEmpty else {
            throw RemoteTunnelProviderError.missingNamedTunnelName
        }
        guard let hostname = hostname(fromPublicURL: configuration.namedTunnelPublicURL) else {
            throw RemoteTunnelProviderError.invalidNamedTunnelPublicURL
        }

        let credentialsFile = normalizedCredentialsFile(from: configuration)
        let localURL = "http://127.0.0.1:\(configuration.localPort)"
        var lines = [
            "tunnel: \(tunnelName)"
        ]
        if let credentialsFile {
            lines.append("credentials-file: \(yamlSingleQuoted(credentialsFile))")
        }
        lines.append(
            contentsOf: [
                "ingress:",
                "  - hostname: \(hostname)",
                "    service: \(localURL)",
                "  - service: http_status:404"
            ]
        )
        return lines.joined(separator: "\n") + "\n"
    }

    private static func writeLocalNamedTunnelConfig(for configuration: RemoteTunnelConfiguration) throws -> URL {
        let tunnelName = configuration.normalizedNamedTunnelName
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("OpenAssist", isDirectory: true)
            .appendingPathComponent("RemoteAccess", isDirectory: true)
            .appendingPathComponent("cloudflared", isDirectory: true)
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("OpenAssist", isDirectory: true)
                .appendingPathComponent("RemoteAccess", isDirectory: true)
                .appendingPathComponent("cloudflared", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configURL = directory.appendingPathComponent("\(safeConfigFileStem(tunnelName)).yml")
        try localNamedTunnelConfigText(for: configuration).write(to: configURL, atomically: true, encoding: .utf8)
        return configURL
    }

    static func resolveExecutablePath(manualOverride: String) -> String? {
        let trimmedOverride = manualOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedOverride.isEmpty,
           FileManager.default.isExecutableFile(atPath: trimmedOverride) {
            return trimmedOverride
        }

        let pathValue = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in pathValue.split(separator: ":").map(String.init) {
            let candidate = URL(fileURLWithPath: directory)
                .appendingPathComponent("cloudflared")
                .path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        let commonPaths = [
            "/opt/homebrew/bin/cloudflared",
            "/usr/local/bin/cloudflared",
            "/usr/bin/cloudflared"
        ]
        return commonPaths.first(where: FileManager.default.isExecutableFile(atPath:))
    }

    static func extractQuickTunnelURL(from line: String) -> URL? {
        let pattern = #"https://[A-Za-z0-9\.-]+\.trycloudflare\.com"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: line,
                range: NSRange(location: 0, length: line.utf16.count)
              ),
              let range = Range(match.range, in: line) else {
            return nil
        }
        return URL(string: String(line[range]))
    }

    static func extractMetricsURL(from line: String) -> URL? {
        let pattern = #"https?://127\.0\.0\.1:\d+/metrics"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: line,
                range: NSRange(location: 0, length: line.utf16.count)
              ),
              let range = Range(match.range, in: line) else {
            return nil
        }
        return URL(string: String(line[range]))
    }

    static func quickTunnelURL(fromMetricsText text: String) -> URL? {
        for line in text.components(separatedBy: .newlines) {
            if line.contains("userHostname"),
               let url = extractQuickTunnelURL(from: line) {
                return url
            }
        }
        return nil
    }

    private static func fetchQuickTunnelURL(fromMetricsURL metricsURL: URL) async -> URL? {
        do {
            let (data, _) = try await URLSession.shared.data(from: metricsURL)
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            return quickTunnelURL(fromMetricsText: text)
        } catch {
            return nil
        }
    }

    static func hostname(fromPublicURL value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        return URL(string: candidate)?.host?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    private static func normalizedCredentialsFile(from configuration: RemoteTunnelConfiguration) -> String? {
        let explicit = expandTilde(configuration.namedTunnelCredentialsFile)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty {
            return explicit
        }

        let tunnelName = configuration.normalizedNamedTunnelName
        guard !tunnelName.isEmpty else { return nil }
        let cloudflaredDirectory = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".cloudflared", isDirectory: true)
        let candidates = [
            cloudflaredDirectory.appendingPathComponent("\(tunnelName).json").path,
            cloudflaredDirectory.appendingPathComponent("\(tunnelName.lowercased()).json").path
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    private static func configurationWithDiscoveredCredentials(
        _ configuration: RemoteTunnelConfiguration,
        cloudflaredPath: String
    ) -> RemoteTunnelConfiguration {
        guard configuration.mode == .named,
              configuration.namedTunnelToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              configuration.namedTunnelCredentialsFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let credentialsFile = discoverCredentialsFile(
                  for: configuration.normalizedNamedTunnelName,
                  cloudflaredPath: cloudflaredPath
              ) else {
            return configuration
        }

        return RemoteTunnelConfiguration(
            mode: configuration.mode,
            transport: configuration.transport,
            localPort: configuration.localPort,
            manualExecutablePath: configuration.manualExecutablePath,
            namedTunnelToken: configuration.namedTunnelToken,
            namedTunnelName: configuration.namedTunnelName,
            namedTunnelPublicURL: configuration.namedTunnelPublicURL,
            namedTunnelCredentialsFile: credentialsFile
        )
    }

    private static func discoverCredentialsFile(for tunnelName: String, cloudflaredPath: String) -> String? {
        let normalizedTunnelName = tunnelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTunnelName.isEmpty else { return nil }

        let cloudflaredDirectory = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".cloudflared", isDirectory: true)
        let directCandidate = cloudflaredDirectory.appendingPathComponent("\(normalizedTunnelName).json").path
        if FileManager.default.fileExists(atPath: directCandidate) {
            return directCandidate
        }

        if let tunnelID = tunnelIDFromCloudflaredInfo(tunnelName: normalizedTunnelName, cloudflaredPath: cloudflaredPath) {
            let idCandidate = cloudflaredDirectory.appendingPathComponent("\(tunnelID).json").path
            if FileManager.default.fileExists(atPath: idCandidate) {
                return idCandidate
            }
        }

        return nil
    }

    static func tunnelID(fromCloudflaredInfoOutput output: String) -> String? {
        let pattern = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: output,
                range: NSRange(location: 0, length: output.utf16.count)
              ),
              let range = Range(match.range, in: output) else {
            return nil
        }
        return String(output[range]).lowercased()
    }

    private static func tunnelIDFromCloudflaredInfo(tunnelName: String, cloudflaredPath: String) -> String? {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: cloudflaredPath)
        process.arguments = ["tunnel", "info", tunnelName]
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData + errorData, encoding: .utf8) ?? ""
            return tunnelID(fromCloudflaredInfoOutput: output)
        } catch {
            return nil
        }
    }

    private static func expandTilde(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("~") else { return trimmed }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if trimmed == "~" {
            return home
        }
        if trimmed.hasPrefix("~/") {
            return home + String(trimmed.dropFirst())
        }
        return trimmed
    }

    private static func yamlSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    private static func safeConfigFileStem(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let characters = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : Character("-") }
        let stem = String(characters).trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return stem.nonEmpty ?? "openassist"
    }
}

private enum RemoteTunnelProviderError: LocalizedError {
    case missingNamedTunnelName
    case invalidNamedTunnelPublicURL

    var errorDescription: String? {
        switch self {
        case .missingNamedTunnelName:
            return "Add a Cloudflare named tunnel name to start the tunnel."
        case .invalidNamedTunnelPublicURL:
            return "Add a valid public hostname for the named tunnel."
        }
    }
}

private extension RemoteTunnelConfiguration {
    var normalizedNamedTunnelName: String {
        namedTunnelName.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
