import CryptoKit
import Foundation
import Security

protocol RemoteAccessSecretStore {
    func load(account: String) -> String
    func store(_ value: String, account: String)
    func delete(account: String)
}

struct KeychainRemoteAccessSecretStore: RemoteAccessSecretStore {
    let service: String

    func load(account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return ""
        }
        return value
    }

    func store(_ rawValue: String, account: String) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            delete(account: account)
            return
        }
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

@MainActor
final class RemoteAccessCoordinator: ObservableObject {
    static let shared = RemoteAccessCoordinator()
    static let defaultPort: UInt16 = 45832
    static let defaultNamedTunnelName = "openassist"
    static let defaultNamedTunnelPublicURL = ""
    private static let keychainService = "com.developingadventures.OpenAssist"
    private static let namedTunnelTokenAccount = "remote-access.named-tunnel-token"
    private static let adminPasswordAccount = "remote-access.admin-password"
    private static let adminPasswordMinimumLength = 8
    private static let adminPasswordPBKDF2Iterations = 120_000
    private static let adminPasswordDerivedKeyLength = 32
    private static let adminPasswordCredentialPrefix = "pbkdf2-sha256"
    private static let pairingLifetimeSeconds: TimeInterval = 5 * 60
    private static let eventPollIntervalSeconds: TimeInterval = 2.0

    private enum Keys {
        static let enabled = "OpenAssist.remoteAccess.enabled"
        static let port = "OpenAssist.remoteAccess.port"
        static let machineID = "OpenAssist.remoteAccess.machineID"
        static let tunnelMode = "OpenAssist.remoteAccess.tunnelMode"
        static let tunnelTransport = "OpenAssist.remoteAccess.tunnelTransport"
        static let namedTunnelName = "OpenAssist.remoteAccess.namedTunnelName"
        static let namedTunnelPublicURL = "OpenAssist.remoteAccess.namedTunnelPublicURL"
        static let namedTunnelCredentialsFile = "OpenAssist.remoteAccess.namedTunnelCredentialsFile"
        static let cloudflaredPathOverride = "OpenAssist.remoteAccess.cloudflaredPathOverride"
        static let pairedDevices = "OpenAssist.remoteAccess.pairedDevices"
    }

    private struct Subscriber {
        let id: UUID
        let deviceID: String?
        let sink: RemoteAccessEventSink
    }

    private final class OwnerBox {
        weak var owner: RemoteAccessCoordinator?
    }

    @Published var remoteAccessEnabled: Bool {
        didSet {
            saveConfiguration()
            applyRuntimeConfiguration()
        }
    }

    @Published var remoteAccessPort: UInt16 {
        didSet {
            let normalized = UInt16(min(Int(UInt16.max), max(1024, Int(remoteAccessPort))))
            guard normalized == remoteAccessPort else {
                remoteAccessPort = normalized
                return
            }
            saveConfiguration()
            applyRuntimeConfiguration()
        }
    }

    @Published var tunnelModeRawValue: String {
        didSet {
            if RemoteTunnelMode(rawValue: tunnelModeRawValue) == nil {
                tunnelModeRawValue = RemoteTunnelMode.disabled.rawValue
                return
            }
            saveConfiguration()
            applyTunnelConfiguration()
        }
    }

    @Published var tunnelTransportRawValue: String {
        didSet {
            if RemoteTunnelTransport(rawValue: tunnelTransportRawValue) == nil {
                tunnelTransportRawValue = RemoteTunnelTransport.auto.rawValue
                return
            }
            saveConfiguration()
            applyTunnelConfiguration()
        }
    }

    @Published var namedTunnelName: String {
        didSet {
            let normalized = namedTunnelName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalized == namedTunnelName else {
                namedTunnelName = normalized
                return
            }
            saveConfiguration()
            applyTunnelConfiguration()
        }
    }

    @Published var namedTunnelPublicURL: String {
        didSet {
            let normalized = namedTunnelPublicURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalized == namedTunnelPublicURL else {
                namedTunnelPublicURL = normalized
                return
            }
            saveConfiguration()
            applyTunnelConfiguration()
        }
    }

    @Published var namedTunnelCredentialsFile: String {
        didSet {
            let normalized = namedTunnelCredentialsFile.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalized == namedTunnelCredentialsFile else {
                namedTunnelCredentialsFile = normalized
                return
            }
            saveConfiguration()
            applyTunnelConfiguration()
        }
    }

    @Published var cloudflaredPathOverride: String {
        didSet {
            let normalized = cloudflaredPathOverride.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalized == cloudflaredPathOverride else {
                cloudflaredPathOverride = normalized
                return
            }
            saveConfiguration()
            applyTunnelConfiguration()
        }
    }

    @Published private(set) var machineID: String
    @Published private(set) var helperState = "Disabled"
    @Published private(set) var helperMessage: String?
    @Published private(set) var tunnelStatus = RemoteAccessTunnelStatus(
        mode: .disabled,
        transport: .auto,
        configured: false,
        isRunning: false,
        publicURL: nil,
        warning: nil,
        detail: "Tunnel disabled.",
        executablePath: nil
    )
    @Published private(set) var pairedDevices: [RemoteAccessPairedDeviceRecord]
    @Published private(set) var activePairingChallenge: RemoteAccessPairingChallenge?
    @Published private(set) var currentSnapshot: RemoteAccessSnapshot?
    @Published private(set) var activeRemoteControl: RemoteAccessControlState?
    @Published private(set) var adminPasswordConfigured: Bool

    private let defaults: UserDefaults
    private let bridge: any RemoteAccessBridge
    private let server: RemoteAccessHTTPServer
    private let tunnelProvider: RemoteTunnelProvider
    private let secretStore: any RemoteAccessSecretStore
    private var subscribers: [UUID: Subscriber] = [:]
    private var pollingTask: Task<Void, Never>?
    private var snapshotSignature: String?
    private var sequence = 0
    private var remoteSelectedSessionIDsByDeviceID: [String: String] = [:]

    var tunnelMode: RemoteTunnelMode {
        RemoteTunnelMode(rawValue: tunnelModeRawValue) ?? .disabled
    }

    var tunnelTransport: RemoteTunnelTransport {
        RemoteTunnelTransport(rawValue: tunnelTransportRawValue) ?? .auto
    }

    var namedTunnelToken: String {
        get { secretStore.load(account: Self.namedTunnelTokenAccount) }
        set {
            secretStore.store(newValue, account: Self.namedTunnelTokenAccount)
            applyTunnelConfiguration()
        }
    }

    var maskedNamedTunnelToken: String {
        let token = namedTunnelToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count > 10 else {
            return token.isEmpty ? "No token saved" : token
        }
        return "\(token.prefix(5))••••\(token.suffix(4))"
    }

    init(
        defaults: UserDefaults = .standard,
        bridge: (any RemoteAccessBridge)? = nil,
        tunnelProvider: RemoteTunnelProvider? = nil,
        secretStore: (any RemoteAccessSecretStore)? = nil
    ) {
        let ownerBox = OwnerBox()
        let resolvedSecretStore = secretStore ?? KeychainRemoteAccessSecretStore(service: Self.keychainService)
        self.defaults = defaults
        self.bridge = bridge ?? AssistantRemoteBridge()
        self.secretStore = resolvedSecretStore
        self.remoteAccessEnabled = defaults.object(forKey: Keys.enabled) == nil
            ? false
            : defaults.bool(forKey: Keys.enabled)
        let storedPort = defaults.object(forKey: Keys.port) == nil
            ? Int(Self.defaultPort)
            : defaults.integer(forKey: Keys.port)
        self.remoteAccessPort = UInt16(min(Int(UInt16.max), max(1024, storedPort)))
        self.machineID = defaults.string(forKey: Keys.machineID)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? UUID().uuidString.lowercased()
        self.tunnelModeRawValue = RemoteTunnelMode(
            rawValue: defaults.string(forKey: Keys.tunnelMode) ?? ""
        )?.rawValue ?? RemoteTunnelMode.disabled.rawValue
        self.tunnelTransportRawValue = RemoteTunnelTransport(
            rawValue: defaults.string(forKey: Keys.tunnelTransport) ?? ""
        )?.rawValue ?? RemoteTunnelTransport.auto.rawValue
        self.namedTunnelName = Self.normalizedStoredNamedTunnelName(
            defaults.string(forKey: Keys.namedTunnelName)
        )
        self.namedTunnelPublicURL = Self.normalizedStoredNamedTunnelPublicURL(
            defaults.string(forKey: Keys.namedTunnelPublicURL)
        )
        self.namedTunnelCredentialsFile = defaults.string(forKey: Keys.namedTunnelCredentialsFile)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.cloudflaredPathOverride = defaults.string(forKey: Keys.cloudflaredPathOverride)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.pairedDevices = Self.loadPairedDeviceRecords(from: defaults, key: Keys.pairedDevices)
        self.adminPasswordConfigured = !resolvedSecretStore.load(account: Self.adminPasswordAccount)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty

        self.server = RemoteAccessHTTPServer(stateHandler: { isRunning, message in
            Task { @MainActor in
                guard let coordinator = ownerBox.owner else { return }
                coordinator.helperState = isRunning ? "Running" : "Stopped"
                coordinator.helperMessage = message
                if !isRunning, coordinator.remoteAccessEnabled == false {
                    coordinator.helperState = "Disabled"
                    coordinator.helperMessage = nil
                }
            }
        })

        let provider = tunnelProvider ?? CloudflaredTunnelProvider()
        self.tunnelProvider = provider
        provider.onStatusChange = { status in
            Task { @MainActor in
                guard let coordinator = ownerBox.owner else { return }
                coordinator.tunnelStatus = status
                await coordinator.refreshAndBroadcastIfNeeded(force: true)
            }
        }

        defaults.set(machineID, forKey: Keys.machineID)
        ownerBox.owner = self
        applyRuntimeConfiguration()
    }

    func rotatePairingChallenge() {
        let suggestedURL = pairingURL(for: tunnelStatus.publicURL ?? localBaseURLString, code: nil)
        let challenge = RemoteAccessPairingChallenge(
            code: Self.makeSecureToken(prefix: "oa_pair_", byteCount: 12),
            expiresAt: Date().addingTimeInterval(Self.pairingLifetimeSeconds),
            createdAt: Date(),
            suggestedURL: suggestedURL?.absoluteString
        )
        activePairingChallenge = challenge
    }

    func clearPairingChallenge() {
        activePairingChallenge = nil
    }

    func installPairingChallenge(_ challenge: RemoteAccessPairingChallenge?) {
        activePairingChallenge = challenge
    }

    func revokeDevice(id: String) {
        pairedDevices.removeAll { $0.id == id }
        remoteSelectedSessionIDsByDeviceID.removeValue(forKey: id)
        if activeRemoteControl?.deviceID == id {
            activeRemoteControl = nil
        }
        saveConfiguration()
    }

    @discardableResult
    func setAdminPassword(_ password: String) -> Bool {
        let normalized = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= Self.adminPasswordMinimumLength else {
            return false
        }
        let credential = Self.makeAdminPasswordCredential(password: normalized)
        secretStore.store(credential, account: Self.adminPasswordAccount)
        adminPasswordConfigured = true
        return true
    }

    func clearAdminPassword() {
        secretStore.delete(account: Self.adminPasswordAccount)
        adminPasswordConfigured = false
    }

    private func storedAdminPasswordCredential() -> String {
        secretStore.load(account: Self.adminPasswordAccount)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func verifyAdminPassword(_ password: String?, credential storedCredential: String? = nil) -> Bool {
        let credential = (storedCredential ?? storedAdminPasswordCredential())
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !credential.isEmpty else {
            adminPasswordConfigured = false
            return true
        }
        adminPasswordConfigured = true
        guard let password = password?.trimmingCharacters(in: .whitespacesAndNewlines),
              !password.isEmpty else {
            return false
        }
        return Self.verifyAdminPassword(password, credential: credential)
    }

    func bestPairingURL() -> URL? {
        guard let challenge = activePairingChallenge else { return nil }
        return pairingURL(for: tunnelStatus.publicURL ?? localBaseURLString, code: challenge.code)
    }

    func remoteControl(for sessionID: String?) -> RemoteAccessControlState? {
        guard let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
              let control = activeRemoteControl,
              control.sessionID.caseInsensitiveCompare(sessionID) == .orderedSame else {
            return nil
        }
        return control
    }

    func isSessionRemoteControlled(_ sessionID: String?) -> Bool {
        remoteControl(for: sessionID) != nil
    }

    func remoteControlBannerText(for sessionID: String?) -> String? {
        guard let control = remoteControl(for: sessionID) else { return nil }
        return "Remote control is active from \(control.deviceName). You can watch this turn, or take over on this Mac."
    }

    func takeOverSession(_ sessionID: String?) {
        guard let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
              activeRemoteControl?.sessionID.caseInsensitiveCompare(sessionID) == .orderedSame else {
            return
        }
        activeRemoteControl = nil
        Task { [weak self] in
            await self?.refreshAndBroadcastIfNeeded(force: true)
        }
    }

    private var machineName: String {
        Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? ProcessInfo.processInfo.hostName
    }

    private var appVersion: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        if let shortVersion, let build, !build.isEmpty {
            return "\(shortVersion) (\(build))"
        }
        return shortVersion ?? "Unknown"
    }

    private var localBaseURLString: String {
        "http://127.0.0.1:\(remoteAccessPort)"
    }

    private static func normalizedStoredNamedTunnelName(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty || trimmed.caseInsensitiveCompare("agent-pulse") == .orderedSame {
            return defaultNamedTunnelName
        }
        return trimmed
    }

    private static func normalizedStoredNamedTunnelPublicURL(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func applyRuntimeConfiguration() {
        if remoteAccessEnabled {
            helperState = "Starting"
            server.start(port: remoteAccessPort) { [weak self] request in
                guard let self else {
                    return .response(AutomationAPIHTTPResponse.error("Remote access helper is unavailable.", statusCode: 503))
                }
                return await self.route(request)
            }
            applyTunnelConfiguration()
        } else {
            pollingTask?.cancel()
            pollingTask = nil
            subscribers.values.forEach { $0.sink.close() }
            subscribers = [:]
            currentSnapshot = nil
            snapshotSignature = nil
            server.stop()
            tunnelProvider.stop()
            helperState = "Disabled"
            helperMessage = nil
            tunnelStatus = RemoteAccessTunnelStatus(
                mode: tunnelMode,
                transport: tunnelTransport,
                configured: false,
                isRunning: false,
                publicURL: nil,
                warning: nil,
                detail: "Tunnel disabled.",
                executablePath: nil
            )
        }
    }

    private func applyTunnelConfiguration() {
        guard remoteAccessEnabled else {
            tunnelProvider.stop()
            return
        }
        tunnelProvider.apply(
            configuration: RemoteTunnelConfiguration(
                mode: tunnelMode,
                transport: tunnelTransport,
                localPort: remoteAccessPort,
                manualExecutablePath: cloudflaredPathOverride,
                namedTunnelToken: namedTunnelToken,
                namedTunnelName: namedTunnelName,
                namedTunnelPublicURL: namedTunnelPublicURL,
                namedTunnelCredentialsFile: namedTunnelCredentialsFile
            )
        )
    }

    private func startPollingIfNeeded() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            guard let self else { return }
            await self.bridge.prime()
            while !Task.isCancelled {
                await self.refreshAndBroadcastIfNeeded(force: false)
                try? await Task.sleep(nanoseconds: UInt64(Self.eventPollIntervalSeconds * 1_000_000_000))
            }
        }
    }

    private func stopPollingIfIdle() {
        guard subscribers.isEmpty else { return }
        pollingTask?.cancel()
        pollingTask = nil
    }

    func route(_ request: AutomationAPIHTTPRequest) async -> RemoteAccessServerResult {
        switch (request.method, request.path) {
        case ("GET", "/"):
            return .response(Self.htmlResponse(html: loadRemoteAccessHTML()))
        case ("GET", "/remote/v1/health"):
            return .response(Self.jsonResponse(makeHealthResponse()))
        case ("POST", "/remote/v1/pair/claim"):
            let decoder = Self.jsonDecoder
            guard let pairRequest = try? decoder.decode(RemoteAccessPairClaimRequest.self, from: request.body) else {
                return .response(AutomationAPIHTTPResponse.error("Invalid pairing request.", statusCode: 400))
            }
            return .response(Self.jsonResponse(await claimPairing(pairRequest, userAgent: request.headerValue(for: "user-agent"))))
        case ("GET", "/remote/v1/state"):
            guard let device = touchAuthorizedDevice(from: request.headerValue(for: "authorization")) else {
                return .response(AutomationAPIHTTPResponse.error("Missing or invalid bearer token.", statusCode: 401))
            }
            await releaseFinishedRemoteControlIfNeeded()
            let snapshot = await buildSnapshot(forDeviceID: device.id)
            return .response(Self.jsonResponse(snapshot))
        case ("POST", "/remote/v1/actions"):
            guard let device = touchAuthorizedDevice(from: request.headerValue(for: "authorization")) else {
                return .response(AutomationAPIHTTPResponse.error("Missing or invalid bearer token.", statusCode: 401))
            }
            let decoder = Self.jsonDecoder
            guard let actionRequest = try? decoder.decode(RemoteAccessActionRequest.self, from: request.body) else {
                return .response(AutomationAPIHTTPResponse.error("Invalid action request.", statusCode: 400))
            }
            let response = await handleAction(actionRequest, device: device)
            return .response(Self.jsonResponse(response, statusCode: response.ok ? 200 : 422))
        case ("GET", "/remote/v1/events"):
            guard let device = touchAuthorizedDevice(from: request.headerValue(for: "authorization")) else {
                return .response(AutomationAPIHTTPResponse.error("Missing or invalid bearer token.", statusCode: 401))
            }
            return .eventStream { [weak self] sink in
                Task { @MainActor in
                    self?.registerSubscriber(sink, deviceID: device.id)
                }
            }
        default:
            return .response(AutomationAPIHTTPResponse.error("Endpoint not found.", statusCode: 404))
        }
    }

    private func registerSubscriber(_ sink: RemoteAccessEventSink, deviceID: String) {
        let id = UUID()
        sink.onClose = { [weak self] in
            Task { @MainActor in
                self?.subscribers.removeValue(forKey: id)
                self?.stopPollingIfIdle()
            }
        }
        subscribers[id] = Subscriber(id: id, deviceID: deviceID, sink: sink)
        startPollingIfNeeded()

        Task { [weak self] in
            guard let self else { return }
            let snapshot = await self.buildSnapshot(forDeviceID: deviceID)
            sink.send(event: self.makeEvent(type: .snapshot, snapshot: snapshot))
        }
    }

    private func refreshAndBroadcastIfNeeded(force: Bool) async {
        await releaseFinishedRemoteControlIfNeeded()
        let snapshot = await buildSnapshot(forDeviceID: nil)
        let previousSnapshot = currentSnapshot

        let signature = Self.snapshotSignature(snapshot)
        guard force || signature != snapshotSignature else {
            currentSnapshot = snapshot
            return
        }

        let eventType = eventTypeForSnapshotChange(previous: previousSnapshot, newSnapshot: snapshot)
        snapshotSignature = signature
        currentSnapshot = snapshot
        for subscriber in subscribers.values {
            let deviceSnapshot = await buildSnapshot(forDeviceID: subscriber.deviceID)
            subscriber.sink.send(event: makeEvent(type: eventType, snapshot: deviceSnapshot))
        }
    }

    private func buildSnapshot(forDeviceID deviceID: String?) async -> RemoteAccessSnapshot {
        let statusSnapshot = bridge.statusSnapshot()
        let preferredSelectedSessionID = deviceID.flatMap {
            remoteSelectedSessionIDsByDeviceID[$0]?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        } ?? statusSnapshot.selectedSessionID
        let sessions = await bridge.listSessions(limit: 40, selectedSessionID: preferredSelectedSessionID)
        let selectedSessionID = preferredSelectedSessionID.flatMap { preferredID in
            sessions.first(where: { $0.id.caseInsensitiveCompare(preferredID) == .orderedSame })?.id
        } ?? sessions.first?.id
        let selectedDetail = await selectedSessionDetail(
            for: selectedSessionID,
            visibleSelectedSessionID: selectedSessionID,
            fallbackSessions: sessions
        )
        let availableModels = await bridge.availableModels()
        let installedPlugins = await bridge.installedCodexPlugins()
        let availableProjects = await bridge.availableProjects()

        return RemoteAccessSnapshot(
            machine: RemoteAccessMachine(
                machineID: machineID,
                displayName: machineName,
                hostName: ProcessInfo.processInfo.hostName,
                appVersion: appVersion,
                operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                localBaseURL: localBaseURLString,
                publicBaseURL: tunnelStatus.publicURL
            ),
            status: RemoteAccessStatus(
                runtimeAvailability: statusSnapshot.runtimeHealth.availability.rawValue,
                runtimeSummary: statusSnapshot.runtimeHealth.summary,
                runtimeDetail: statusSnapshot.runtimeHealth.detail,
                helperState: helperState,
                helperMessage: helperMessage,
                tunnel: tunnelStatus,
                usage: Self.makeRemoteUsage(
                    backend: statusSnapshot.assistantBackend,
                    rateLimits: statusSnapshot.rateLimits,
                    tokenUsage: statusSnapshot.tokenUsage
                )
            ),
            pairedDevice: deviceID.flatMap { deviceRecord in
                pairedDevices.first(where: { $0.id == deviceRecord }).map {
                    RemoteAccessPairedDevice(
                        id: $0.id,
                        name: $0.name,
                        createdAt: $0.createdAt,
                        lastSeenAt: $0.lastSeenAt,
                        userAgent: $0.userAgent,
                        isCurrent: true
                    )
                }
            },
            sessions: sessions.map(mapSession),
            selectedSessionID: selectedSessionID,
            selectedSession: selectedDetail,
            remoteControl: activeRemoteControl,
            availableBackends: bridge.availableBackends().map {
                RemoteAccessBackendOption(id: $0.rawValue, displayName: $0.displayName)
            },
            availableModels: availableModels.map {
                RemoteAccessModelOption(
                    id: $0.id,
                    displayName: $0.displayName,
                    description: $0.description,
                    isDefault: $0.isDefault,
                    inputModalities: $0.inputModalities,
                    supportedReasoningEfforts: $0.supportedReasoningEfforts
                )
            },
            installedPlugins: installedPlugins.map {
                RemoteAccessPlugin(
                    id: $0.pluginID,
                    displayName: $0.displayName,
                    summary: $0.summary,
                    needsSetup: $0.needsSetup,
                    iconDataURL: $0.iconDataURL
                )
            },
            projects: availableProjects.map {
                RemoteAccessProject(
                    id: $0.id,
                    name: $0.name,
                    kind: $0.kind.rawValue,
                    parentID: $0.parentID,
                    sessionCount: $0.sessionCount
                )
            }
        )
    }

    private static func makeRemoteUsage(
        backend: AssistantRuntimeBackend,
        rateLimits: AccountRateLimits,
        tokenUsage: TokenUsageSnapshot
    ) -> RemoteAccessUsage? {
        // We surface cloud provider usage when the provider exposes it. Ollama
        // runs locally so it has no quota to report.
        switch backend {
        case .ollamaLocal:
            return nil
        case .codex, .copilot, .claudeCode, .antigravityCLI:
            break
        }

        let bucket = rateLimits.defaultBucket ?? rateLimits.additionalBuckets.first
        let primary = bucket?.primary.flatMap(makeRemoteUsageWindow)
        let secondary = bucket?.secondary.flatMap(makeRemoteUsageWindow)
        let context = makeRemoteContextUsage(tokenUsage)

        // Surface the usage block whenever any of the three components are
        // available — even if rate limits aren't loaded yet, we can still
        // show the context circle.
        guard primary != nil || secondary != nil || context != nil else {
            return nil
        }

        return RemoteAccessUsage(
            providerBackend: backend.rawValue,
            providerLabel: backend.displayName,
            planType: rateLimits.planType,
            primary: primary,
            secondary: secondary,
            context: context
        )
    }

    private static func makeRemoteContextUsage(_ tokenUsage: TokenUsageSnapshot) -> RemoteAccessContextUsage? {
        guard let fraction = tokenUsage.contextUsageFraction else { return nil }
        let usedPercent = max(0, min(100, Int(round(fraction * 100))))
        return RemoteAccessContextUsage(
            usedPercent: usedPercent,
            summary: tokenUsage.contextSummary,
            detail: tokenUsage.contextTooltipDetail
        )
    }

    private static func makeRemoteUsageWindow(_ window: RateLimitWindow) -> RemoteAccessUsageWindow? {
        let label = window.windowLabel.isEmpty ? "" : window.windowLabel
        return RemoteAccessUsageWindow(
            label: label,
            usedPercent: max(0, min(100, window.usedPercent)),
            resetsAt: window.resetsAt,
            resetsInLabel: window.resetsInLabel
        )
    }

    private func selectedSessionDetail(
        for sessionID: String?,
        visibleSelectedSessionID: String? = nil,
        fallbackSessions: [AssistantSessionSummary] = []
    ) async -> RemoteAccessSessionDetail? {
        guard let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return nil
        }

        if let snapshot = await bridge.sessionSnapshot(
            sessionID: sessionID,
            selectedSessionID: visibleSelectedSessionID ?? sessionID
        ) {
            let selectedPluginIDs = await bridge.selectedPluginIDs(
                sessionID: sessionID,
                preserveVisibleSelection: true
            )
            let pendingPermission = snapshot.pendingPermissionRequest.map(mapPermission)
            return RemoteAccessSessionDetail(
                session: mapSession(snapshot.session),
                transcript: snapshot.transcriptEntries.map(mapTranscriptEntry),
                activeToolCalls: snapshot.toolCalls.map(mapToolCall),
                recentToolCalls: snapshot.recentToolCalls.map(mapToolCall),
                pendingPermission: pendingPermission,
                selectedPluginIDs: selectedPluginIDs,
                pendingOutgoingMessage: snapshot.pendingOutgoingMessage?.text,
                activeTurnID: snapshot.activeTurnID,
                awaitingAssistantStart: snapshot.awaitingAssistantStart,
                queuedPromptCount: snapshot.queuedPromptCount
            )
        }

        guard let fallbackSession = fallbackSessions.first(where: {
            $0.id.caseInsensitiveCompare(sessionID) == .orderedSame
        }) else {
            return nil
        }

        return RemoteAccessSessionDetail(
            session: mapSession(fallbackSession),
            transcript: [],
            activeToolCalls: [],
            recentToolCalls: [],
            pendingPermission: nil,
            selectedPluginIDs: [],
            pendingOutgoingMessage: nil,
            activeTurnID: nil,
            awaitingAssistantStart: false,
            queuedPromptCount: 0
        )
    }

    private func handleAction(
        _ request: RemoteAccessActionRequest,
        device: RemoteAccessPairedDeviceRecord
    ) async -> RemoteAccessActionResponse {
        if let requestedMachineID = request.machineID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
           requestedMachineID.caseInsensitiveCompare(machineID) != .orderedSame {
            return RemoteAccessActionResponse(
                id: request.id,
                ok: false,
                snapshot: nil,
                error: "This request targets a different machine."
            )
        }

        do {
            switch request.type {
            case .selectSession:
                guard let sessionID = request.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
                    throw RemoteAccessError.invalidRequest("Missing sessionID.")
                }
                guard await bridge.sessionSnapshot(
                    sessionID: sessionID,
                    selectedSessionID: sessionID
                ) != nil else {
                    throw RemoteAccessError.invalidRequest("Session not found.")
                }
                remoteSelectedSessionIDsByDeviceID[device.id] = sessionID
            case .newSession:
                let payload = request.payload?.objectValue ?? [:]
                let temporary = payload["temporary"]?.boolValue ?? false
                let projectID = payload["projectID"]?.stringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty
                let newSession: AssistantRemoteSessionSnapshot?
                if temporary {
                    newSession = await bridge.startNewTemporarySession(
                        projectID: projectID,
                        preserveVisibleSelection: true
                    )
                } else {
                    newSession = await bridge.startNewSession(
                        projectID: projectID,
                        preserveVisibleSelection: true
                    )
                }
                guard let newSession else {
                    throw RemoteAccessError.invalidRequest("Could not start a new chat.")
                }
                remoteSelectedSessionIDsByDeviceID[device.id] = newSession.session.id
            case .sendPrompt:
                let targetSessionID = remoteTargetSessionID(for: request, device: device)
                try ensureDeviceMayControlSession(targetSessionID, device: device)
                if let targetSessionID {
                    acquireRemoteControl(
                        sessionID: targetSessionID,
                        device: device,
                        activeTurnID: nil
                    )
                }
                let payload = request.payload?.objectValue ?? [:]
                guard let prompt = payload["prompt"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !prompt.isEmpty else {
                    throw RemoteAccessError.invalidRequest("Prompt text is required.")
                }
                let selectedPluginIDs = payload["selectedPluginIDs"]?.stringArrayValue ?? []
                let oneShotInstructions = payload["oneShotInstructions"]?.stringValue
                guard let remoteSession = await bridge.sendPrompt(
                    prompt,
                    sessionID: targetSessionID,
                    projectID: nil,
                    selectedPluginIDs: selectedPluginIDs,
                    oneShotInstructions: oneShotInstructions,
                    preserveVisibleSelection: true
                ) else {
                    throw RemoteAccessError.invalidRequest("Could not send the prompt.")
                }
                remoteSelectedSessionIDsByDeviceID[device.id] = remoteSession.session.id
                acquireRemoteControl(
                    sessionID: remoteSession.session.id,
                    device: device,
                    activeTurnID: remoteSession.activeTurnID
                )
            case .stopTurn:
                let targetSessionID = remoteTargetSessionID(for: request, device: device)
                try ensureDeviceMayControlSession(targetSessionID, device: device)
                await bridge.cancelActiveTurn(
                    sessionID: targetSessionID,
                    preserveVisibleSelection: true
                )
            case .chooseModel:
                let targetSessionID = remoteTargetSessionID(for: request, device: device)
                try ensureDeviceMayControlSession(targetSessionID, device: device)
                guard let modelID = request.payload?.objectValue?["modelID"]?.stringValue,
                      await bridge.chooseModel(
                          modelID,
                          sessionID: targetSessionID,
                          preserveVisibleSelection: true
                      ) else {
                    throw RemoteAccessError.invalidRequest("Model is unavailable.")
                }
            case .chooseBackend:
                let targetSessionID = remoteTargetSessionID(for: request, device: device)
                try ensureDeviceMayControlSession(targetSessionID, device: device)
                guard let backendRawValue = request.payload?.objectValue?["backend"]?.stringValue,
                      let backend = AssistantRuntimeBackend(rawValue: backendRawValue),
                      await bridge.selectBackend(
                          backend,
                          sessionID: targetSessionID,
                          preserveVisibleSelection: true
                      ) else {
                    throw RemoteAccessError.invalidRequest("Backend is unavailable.")
                }
            case .setMode:
                let targetSessionID = remoteTargetSessionID(for: request, device: device)
                try ensureDeviceMayControlSession(targetSessionID, device: device)
                guard let modeRawValue = request.payload?.objectValue?["mode"]?.stringValue,
                      let mode = AssistantInteractionMode(rawValue: modeRawValue) else {
                    throw RemoteAccessError.invalidRequest("Mode is unavailable.")
                }
                await bridge.setInteractionMode(
                    mode,
                    sessionID: targetSessionID,
                    preserveVisibleSelection: true
                )
            case .setReasoningEffort:
                let targetSessionID = remoteTargetSessionID(for: request, device: device)
                try ensureDeviceMayControlSession(targetSessionID, device: device)
                guard let effortRawValue = request.payload?.objectValue?["reasoningEffort"]?.stringValue,
                      let effort = AssistantReasoningEffort(rawValue: effortRawValue) else {
                    throw RemoteAccessError.invalidRequest("Reasoning effort is unavailable.")
                }
                await bridge.setReasoningEffort(
                    effort,
                    sessionID: targetSessionID,
                    preserveVisibleSelection: true
                )
            case .applyPlugins:
                let targetSessionID = remoteTargetSessionID(for: request, device: device)
                try ensureDeviceMayControlSession(targetSessionID, device: device)
                let ids = request.payload?.objectValue?["pluginIDs"]?.stringArrayValue ?? []
                guard await bridge.applyPlugins(
                    ids,
                    sessionID: targetSessionID,
                    preserveVisibleSelection: true
                ) else {
                    throw RemoteAccessError.invalidRequest("One or more plugins are unavailable.")
                }
            case .resolvePermission:
                let targetSessionID = remoteTargetSessionID(for: request, device: device)
                try ensureDeviceMayControlSession(targetSessionID, device: device)
                guard let detail = await selectedSessionDetail(
                    for: targetSessionID,
                    visibleSelectedSessionID: targetSessionID
                ),
                      let pendingPermission = detail.pendingPermission else {
                    throw RemoteAccessError.invalidRequest("There is no active permission request.")
                }
                let payload = request.payload?.objectValue ?? [:]
                guard payload["requestID"]?.intValue == pendingPermission.id else {
                    throw RemoteAccessError.invalidRequest("That permission request is stale.")
                }
                if pendingPermission.requiresDesktopAppConfirmation {
                    throw RemoteAccessError.invalidRequest("Finish this confirmation on the Mac.")
                }
                if let optionID = payload["optionID"]?.stringValue {
                    await bridge.resolvePermission(
                        optionID: optionID,
                        sessionID: targetSessionID,
                        preserveVisibleSelection: true
                    )
                } else if let answers = payload["answers"]?.stringDictionaryArrayValue {
                    await bridge.resolvePermission(
                        answers: answers,
                        sessionID: targetSessionID,
                        preserveVisibleSelection: true
                    )
                } else {
                    throw RemoteAccessError.invalidRequest("Missing permission response payload.")
                }
            case .cancelPermission:
                let targetSessionID = remoteTargetSessionID(for: request, device: device)
                try ensureDeviceMayControlSession(targetSessionID, device: device)
                guard let detail = await selectedSessionDetail(
                    for: targetSessionID,
                    visibleSelectedSessionID: targetSessionID
                ),
                      let pendingPermission = detail.pendingPermission else {
                    throw RemoteAccessError.invalidRequest("There is no active permission request.")
                }
                let payload = request.payload?.objectValue ?? [:]
                guard payload["requestID"]?.intValue == pendingPermission.id else {
                    throw RemoteAccessError.invalidRequest("That permission request is stale.")
                }
                await bridge.cancelPendingPermissionRequest(
                    sessionID: targetSessionID,
                    preserveVisibleSelection: true
                )
            case .deleteSession:
                let targetSessionID = remoteTargetSessionID(for: request, device: device)
                try ensureDeviceMayControlSession(targetSessionID, device: device)
                guard let sessionID = targetSessionID else {
                    throw RemoteAccessError.invalidRequest("Missing sessionID.")
                }
                guard await bridge.archiveSession(sessionID: sessionID) else {
                    throw RemoteAccessError.invalidRequest("Could not archive the thread.")
                }
                if let control = activeRemoteControl,
                   control.sessionID.caseInsensitiveCompare(sessionID) == .orderedSame {
                    activeRemoteControl = nil
                }
            }

            let snapshot = await buildSnapshot(forDeviceID: device.id)
            snapshotSignature = Self.snapshotSignature(snapshot)
            currentSnapshot = snapshot
            return RemoteAccessActionResponse(id: request.id, ok: true, snapshot: snapshot, error: nil)
        } catch let error as RemoteAccessError {
            return RemoteAccessActionResponse(id: request.id, ok: false, snapshot: nil, error: error.localizedDescription)
        } catch {
            return RemoteAccessActionResponse(id: request.id, ok: false, snapshot: nil, error: error.localizedDescription)
        }
    }

    private func ensureDeviceMayControlSession(
        _ sessionID: String?,
        device: RemoteAccessPairedDeviceRecord
    ) throws {
        guard let control = activeRemoteControl,
              control.deviceID != device.id else {
            return
        }
        guard let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
              control.sessionID.caseInsensitiveCompare(sessionID) == .orderedSame else {
            return
        }
        throw RemoteAccessError.invalidRequest("This thread is being controlled from \(control.deviceName).")
    }

    private func remoteTargetSessionID(
        for request: RemoteAccessActionRequest,
        device: RemoteAccessPairedDeviceRecord
    ) -> String? {
        request.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? remoteSelectedSessionIDsByDeviceID[device.id]?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    private func acquireRemoteControl(
        sessionID: String,
        device: RemoteAccessPairedDeviceRecord,
        activeTurnID: String?
    ) {
        activeRemoteControl = RemoteAccessControlState(
            sessionID: sessionID,
            deviceID: device.id,
            deviceName: device.name,
            acquiredAt: Date(),
            activeTurnID: activeTurnID
        )
    }

    private func releaseFinishedRemoteControlIfNeeded() async {
        guard let control = activeRemoteControl else { return }
        guard let snapshot = await bridge.sessionSnapshot(sessionID: control.sessionID) else {
            activeRemoteControl = nil
            return
        }

        let stillWorking = snapshot.activeTurnID != nil
            || snapshot.awaitingAssistantStart
            || snapshot.pendingOutgoingMessage != nil
            || snapshot.queuedPromptCount > 0
            || snapshot.hasActiveTurn
        guard stillWorking else {
            activeRemoteControl = nil
            return
        }

        if snapshot.activeTurnID != control.activeTurnID {
            activeRemoteControl = RemoteAccessControlState(
                sessionID: control.sessionID,
                deviceID: control.deviceID,
                deviceName: control.deviceName,
                acquiredAt: control.acquiredAt,
                activeTurnID: snapshot.activeTurnID
            )
        }
    }

    private func claimPairing(
        _ request: RemoteAccessPairClaimRequest,
        userAgent: String?
    ) async -> RemoteAccessPairClaimResponse {
        let suppliedAdminPassword = request.adminPassword?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
        let adminPasswordCredential = storedAdminPasswordCredential()

        if !adminPasswordCredential.isEmpty {
            adminPasswordConfigured = true
            guard let suppliedAdminPassword else {
                return RemoteAccessPairClaimResponse(
                    ok: false,
                    machineID: nil,
                    deviceToken: nil,
                    snapshot: nil,
                    error: "Enter the Remote Access password."
                )
            }
            guard verifyAdminPassword(suppliedAdminPassword, credential: adminPasswordCredential) else {
                return RemoteAccessPairClaimResponse(
                    ok: false,
                    machineID: nil,
                    deviceToken: nil,
                    snapshot: nil,
                    error: "That Remote Access password is incorrect."
                )
            }
            if let challenge = activePairingChallenge, challenge.expiresAt < Date() {
                activePairingChallenge = nil
            }
            return await completePairing(request, userAgent: userAgent)
        }

        guard let challenge = activePairingChallenge else {
            return RemoteAccessPairClaimResponse(
                ok: false,
                machineID: nil,
                deviceToken: nil,
                snapshot: nil,
                error: "There is no active pairing code."
            )
        }
        guard challenge.expiresAt >= Date() else {
            activePairingChallenge = nil
            return RemoteAccessPairClaimResponse(
                ok: false,
                machineID: nil,
                deviceToken: nil,
                snapshot: nil,
                error: "That pairing code has expired."
            )
        }
        guard challenge.code == request.code?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return RemoteAccessPairClaimResponse(
                ok: false,
                machineID: nil,
                deviceToken: nil,
                snapshot: nil,
                error: "That pairing code is invalid."
            )
        }

        return await completePairing(request, userAgent: userAgent)
    }

    private func completePairing(
        _ request: RemoteAccessPairClaimRequest,
        userAgent: String?
    ) async -> RemoteAccessPairClaimResponse {
        let deviceToken = Self.makeSecureToken(prefix: "oa_dev_", byteCount: 24)
        let requestedName = request.deviceName?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let fallbackName = Self.deviceNameFromUserAgent(userAgent)
        let device = RemoteAccessPairedDeviceRecord(
            id: UUID().uuidString.lowercased(),
            name: requestedName ?? fallbackName,
            tokenHash: Self.sha256Hex(deviceToken),
            createdAt: Date(),
            lastSeenAt: Date(),
            userAgent: userAgent?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        )
        pairedDevices.removeAll {
            $0.name.caseInsensitiveCompare(device.name) == .orderedSame
                && $0.userAgent == device.userAgent
        }
        pairedDevices.append(device)
        pairedDevices.sort { $0.createdAt > $1.createdAt }
        activePairingChallenge = nil
        saveConfiguration()

        let snapshot = await buildSnapshot(forDeviceID: device.id)
        currentSnapshot = snapshot
        return RemoteAccessPairClaimResponse(
            ok: true,
            machineID: machineID,
            deviceToken: deviceToken,
            snapshot: snapshot,
            error: nil
        )
    }

    private func touchAuthorizedDevice(from authorizationHeader: String?) -> RemoteAccessPairedDeviceRecord? {
        guard let token = AutomationAPIAuthorization.bearerToken(from: authorizationHeader) else {
            return nil
        }
        let tokenHash = Self.sha256Hex(token)
        guard let index = pairedDevices.firstIndex(where: { $0.tokenHash == tokenHash }) else {
            return nil
        }
        pairedDevices[index].lastSeenAt = Date()
        saveConfiguration()
        return pairedDevices[index]
    }

    private func makeHealthResponse() -> RemoteAccessHealthResponse {
        RemoteAccessHealthResponse(
            ok: true,
            helperState: helperState,
            helperMessage: helperMessage,
            machineID: machineID,
            machineName: machineName,
            appVersion: appVersion,
            localBaseURL: localBaseURLString,
            publicBaseURL: tunnelStatus.publicURL,
            tunnelMode: tunnelMode.rawValue,
            adminPasswordRequired: adminPasswordConfigured
        )
    }

    private func eventTypeForSnapshotChange(
        previous: RemoteAccessSnapshot?,
        newSnapshot: RemoteAccessSnapshot
    ) -> RemoteAccessEventType {
        guard let previous else {
            return .snapshot
        }
        if previous.status != newSnapshot.status {
            return .statusChanged
        }
        let previousPermission = previous.selectedSession?.pendingPermission?.id
        let newPermission = newSnapshot.selectedSession?.pendingPermission?.id
        if previousPermission != newPermission {
            return .permissionUpdated
        }
        return .sessionUpdated
    }

    private func makeEvent(type: RemoteAccessEventType, snapshot: RemoteAccessSnapshot?) -> RemoteAccessEvent {
        sequence += 1
        return RemoteAccessEvent(sequence: sequence, type: type, snapshot: snapshot)
    }

    private func mapSession(_ session: AssistantSessionSummary) -> RemoteAccessSession {
        RemoteAccessSession(
            id: session.id,
            title: session.title,
            summary: session.summary?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                ?? session.latestAssistantMessage?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                ?? session.latestUserMessage?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            projectID: session.projectID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            projectName: session.projectName,
            backend: session.activeProvider?.rawValue ?? session.providerBackend?.rawValue,
            modelID: session.latestModel,
            interactionMode: session.latestInteractionMode?.rawValue,
            reasoningEffort: session.latestReasoningEffort?.rawValue,
            isTemporary: session.isTemporary,
            hasActiveTurn: session.status == .active,
            updatedAt: session.updatedAt
        )
    }

    private func mapTranscriptEntry(_ entry: AssistantTranscriptEntry) -> RemoteAccessTranscriptEntry {
        RemoteAccessTranscriptEntry(
            id: entry.id.uuidString.lowercased(),
            role: entry.role.rawValue,
            text: entry.text,
            createdAt: entry.createdAt,
            isStreaming: entry.isStreaming,
            providerBackend: entry.providerBackend?.rawValue,
            providerModelID: entry.providerModelID,
            selectedPluginIDs: entry.selectedPlugins?.map(\.pluginID) ?? []
        )
    }

    private func mapToolCall(_ call: AssistantToolCallState) -> RemoteAccessToolCall {
        RemoteAccessToolCall(id: call.id, title: call.title, status: call.status, detail: call.detail)
    }

    private func mapPermission(_ permission: AssistantPermissionRequest) -> RemoteAccessPermissionRequest {
        RemoteAccessPermissionRequest(
            id: permission.id,
            toolTitle: permission.toolTitle,
            toolKind: permission.toolKind,
            rationale: permission.rationale,
            rawPayloadSummary: permission.rawPayloadSummary,
            requiresDesktopAppConfirmation: permission.requiresDesktopAppConfirmation,
            options: permission.options.map {
                RemoteAccessPermissionOption(
                    id: $0.id,
                    title: $0.title,
                    kind: $0.kind,
                    isDefault: $0.isDefault
                )
            },
            questions: permission.userInputQuestions.map {
                RemoteAccessPermissionQuestion(
                    id: $0.id,
                    header: $0.header,
                    prompt: $0.prompt,
                    allowsCustomAnswer: $0.allowsCustomAnswer,
                    options: $0.options.map {
                        RemoteAccessPermissionQuestionOption(
                            id: $0.id,
                            label: $0.label,
                            detail: $0.detail
                        )
                    }
                )
            }
        )
    }

    private func saveConfiguration() {
        defaults.set(remoteAccessEnabled, forKey: Keys.enabled)
        defaults.set(Int(remoteAccessPort), forKey: Keys.port)
        defaults.set(machineID, forKey: Keys.machineID)
        defaults.set(tunnelModeRawValue, forKey: Keys.tunnelMode)
        defaults.set(tunnelTransportRawValue, forKey: Keys.tunnelTransport)
        defaults.set(namedTunnelName, forKey: Keys.namedTunnelName)
        defaults.set(namedTunnelPublicURL, forKey: Keys.namedTunnelPublicURL)
        defaults.set(namedTunnelCredentialsFile, forKey: Keys.namedTunnelCredentialsFile)
        defaults.set(cloudflaredPathOverride, forKey: Keys.cloudflaredPathOverride)
        defaults.set(Self.encodePairedDevices(pairedDevices), forKey: Keys.pairedDevices)
    }

    private func loadRemoteAccessHTML() -> String {
        let url: URL? =
            Bundle.main.url(forResource: "remote-access", withExtension: "html")
            ?? Bundle(identifier: "OpenAssist_OpenAssist")?.url(forResource: "remote-access", withExtension: "html")
            ?? {
                let execDir = Bundle.main.bundleURL.deletingLastPathComponent()
                let candidates = [
                    execDir.appendingPathComponent("OpenAssist_OpenAssist.bundle/remote-access.html"),
                    execDir.appendingPathComponent("remote-access.html")
                ]
                return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
            }()

        guard let url,
              let html = try? String(contentsOf: url, encoding: .utf8) else {
            return "<!doctype html><html><body><h1>Remote Access UI is unavailable.</h1></body></html>"
        }
        return html
    }

    private static var jsonEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var jsonDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func jsonResponse<T: Encodable>(
        _ value: T,
        statusCode: Int = 200
    ) -> AutomationAPIHTTPResponse {
        let encoder = jsonEncoder
        let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return AutomationAPIHTTPResponse(
            statusCode: statusCode,
            reasonPhrase: {
                switch statusCode {
                case 200: return "OK"
                case 400: return "Bad Request"
                case 401: return "Unauthorized"
                case 404: return "Not Found"
                case 422: return "Unprocessable Entity"
                default: return "OK"
                }
            }(),
            headers: [
                "Content-Type": "application/json; charset=utf-8",
                "Cache-Control": "no-store"
            ],
            body: data
        )
    }

    private static func htmlResponse(html: String) -> AutomationAPIHTTPResponse {
        AutomationAPIHTTPResponse(
            statusCode: 200,
            reasonPhrase: "OK",
            headers: [
                "Content-Type": "text/html; charset=utf-8",
                "Cache-Control": "no-store"
            ],
            body: Data(html.utf8)
        )
    }

    private static func makeSecureToken(prefix: String, byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: max(1, byteCount))
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status == errSecSuccess {
            return prefix + Data(bytes).base64EncodedString()
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "=", with: "")
        }
        return prefix + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func makeAdminPasswordCredential(password: String) -> String {
        let salt = secureRandomData(byteCount: 16)
        let derivedKey = pbkdf2SHA256(
            password: Data(password.utf8),
            salt: salt,
            iterations: adminPasswordPBKDF2Iterations,
            keyLength: adminPasswordDerivedKeyLength
        )
        return [
            adminPasswordCredentialPrefix,
            String(adminPasswordPBKDF2Iterations),
            base64URLEncoded(salt),
            base64URLEncoded(derivedKey)
        ].joined(separator: "$")
    }

    static func verifyAdminPassword(_ password: String, credential: String) -> Bool {
        let parts = credential.split(separator: "$", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4,
              parts[0] == adminPasswordCredentialPrefix,
              let iterations = Int(parts[1]),
              iterations > 0,
              let salt = base64URLDecoded(parts[2]),
              let expectedKey = base64URLDecoded(parts[3]),
              !expectedKey.isEmpty else {
            return false
        }
        let actualKey = pbkdf2SHA256(
            password: Data(password.utf8),
            salt: salt,
            iterations: iterations,
            keyLength: expectedKey.count
        )
        return constantTimeEquals([UInt8](actualKey), [UInt8](expectedKey))
    }

    private static func secureRandomData(byteCount: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: max(1, byteCount))
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            bytes = Array(UUID().uuidString.utf8)
        }
        return Data(bytes)
    }

    private static func pbkdf2SHA256(
        password: Data,
        salt: Data,
        iterations: Int,
        keyLength: Int
    ) -> Data {
        let key = SymmetricKey(data: password)
        let hashLength = 32
        let blockCount = Int(ceil(Double(keyLength) / Double(hashLength)))
        var derived = [UInt8]()
        derived.reserveCapacity(blockCount * hashLength)

        for blockIndex in 1...blockCount {
            var saltAndCounter = Data(salt)
            var counter = UInt32(blockIndex).bigEndian
            withUnsafeBytes(of: &counter) { saltAndCounter.append(contentsOf: $0) }

            var u = Array(HMAC<SHA256>.authenticationCode(for: saltAndCounter, using: key))
            var block = u
            if iterations > 1 {
                for _ in 1..<iterations {
                    u = Array(HMAC<SHA256>.authenticationCode(for: Data(u), using: key))
                    for index in block.indices {
                        block[index] ^= u[index]
                    }
                }
            }
            derived.append(contentsOf: block)
        }

        return Data(derived.prefix(keyLength))
    }

    private static func constantTimeEquals(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for index in lhs.indices {
            diff |= lhs[index] ^ rhs[index]
        }
        return diff == 0
    }

    private static func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLDecoded(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        if padding > 0 {
            base64.append(String(repeating: "=", count: padding))
        }
        return Data(base64Encoded: base64)
    }

    private static func snapshotSignature(_ snapshot: RemoteAccessSnapshot) -> String {
        let encoder = jsonEncoder
        let data = (try? encoder.encode(snapshot)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func encodePairedDevices(_ devices: [RemoteAccessPairedDeviceRecord]) -> Data? {
        try? jsonEncoder.encode(devices)
    }

    private static func loadPairedDeviceRecords(
        from defaults: UserDefaults,
        key: String
    ) -> [RemoteAccessPairedDeviceRecord] {
        guard let data = defaults.data(forKey: key),
              let devices = try? jsonDecoder.decode([RemoteAccessPairedDeviceRecord].self, from: data) else {
            return []
        }
        return devices.sorted { $0.createdAt > $1.createdAt }
    }

    private static func deviceNameFromUserAgent(_ userAgent: String?) -> String {
        let normalized = userAgent?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if normalized.contains("iphone") {
            return "iPhone Browser"
        }
        if normalized.contains("ipad") {
            return "iPad Browser"
        }
        if normalized.contains("watch") {
            return "Watch Browser"
        }
        if normalized.contains("android") {
            return "Android Browser"
        }
        return "Remote Browser"
    }

    private func pairingURL(for baseURLString: String?, code: String?) -> URL? {
        guard let baseURLString = baseURLString?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
              var components = URLComponents(string: baseURLString) else {
            return nil
        }
        if let code {
            components.queryItems = (components.queryItems ?? []) + [
                URLQueryItem(name: "pairingCode", value: code)
            ]
        }
        return components.url
    }

    private static func loadKeychainValue(account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return ""
        }
        return value
    }

    private static func storeKeychainValue(_ rawValue: String, account: String) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            deleteKeychainValue(account: account)
            return
        }
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus == errSecItemNotFound {
            var create = query
            create[kSecValueData as String] = data
            _ = SecItemAdd(create as CFDictionary, nil)
        }
    }

    private static func deleteKeychainValue(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        _ = SecItemDelete(query as CFDictionary)
    }
}

private enum RemoteAccessError: LocalizedError {
    case invalidRequest(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest(let message):
            return message
        }
    }
}

private extension RemoteAccessJSONValue {
    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        if case .number(let value) = self { return Int(value) }
        return nil
    }

    var objectValue: [String: RemoteAccessJSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var stringArrayValue: [String] {
        guard case .array(let values) = self else { return [] }
        return values.compactMap(\.stringValue)
    }

    var stringDictionaryArrayValue: [String: [String]] {
        guard case .object(let value) = self else { return [:] }
        return value.reduce(into: [String: [String]]()) { result, entry in
            result[entry.key] = entry.value.stringArrayValue
        }
    }
}
