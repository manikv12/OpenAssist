import AppKit
import AVFoundation
import Foundation
import UserNotifications

@MainActor
final class AutomationAPICoordinator: NSObject, ObservableObject {
    static let shared = AutomationAPICoordinator()
    private static let codexCloudPollIntervalNanoseconds: UInt64 = 60_000_000_000
    private static let automationNotificationIdentifierPrefix = "openassist-automation-"
    private static let automationNotificationUserInfoKey = "openassistAutomation"

    @Published private(set) var isServerRunning = false
    @Published private(set) var serverMessage: String?
    @Published private(set) var serverState = "disabled"
    @Published private(set) var notificationAuthorizationState: AutomationAPINotificationAuthorizationState = .unknown
    @Published private(set) var availableVoices: [AutomationAPIVoiceOption] = []
    @Published private(set) var codexCLIStatusMessage = "Checking Codex CLI…"
    @Published private(set) var codexCloudStatusMessage = "Disabled"

    private lazy var server: LocalAutomationServer = LocalAutomationServer { [weak self] isRunning, message in
        Task { @MainActor in
            self?.isServerRunning = isRunning
            self?.serverMessage = message
            if isRunning {
                self?.serverState = "running"
            } else if let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self?.serverState = "failed"
            } else {
                self?.serverState = "disabled"
            }
        }
    }
    private let notificationCenter = UNUserNotificationCenter.current()
    private let speechSynthesizer = AVSpeechSynthesizer()
    private let dedupeStore = AutomationAPIDedupeStore()
    private let codexCommandRunner: CodexCommandRunning = CodexCommandRunner()
    private let codexCloudTaskTracker = CodexCloudTaskTracker()
    private var currentConfiguration: AutomationAPIServerConfiguration?
    private weak var settings: SettingsStore?
    private var codexCloudMonitoringTask: Task<Void, Never>?
    private var lastCodexCloudLoggedError: String?
    private var notificationInteractionHandler: (@MainActor (_ source: String?) -> Void)?

    private override init() {
        super.init()
        notificationCenter.delegate = self
        refreshAvailableVoices()
        Task {
            await refreshNotificationAuthorizationState()
        }
    }

    var serverStatusText: String {
        if let serverMessage, !serverMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return serverMessage
        }
        if serverState == "starting", let port = currentConfiguration?.port {
            return "Starting on 127.0.0.1:\(port)"
        }
        if isServerRunning, let port = currentConfiguration?.port {
            return "Running on 127.0.0.1:\(port)"
        }
        return "Disabled"
    }

    var notificationsAllowed: Bool {
        switch notificationAuthorizationState {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined, .denied, .unknown:
            return false
        }
    }

    func applySettings(_ settings: SettingsStore) {
        self.settings = settings
        refreshAvailableVoices()
        let configuration = settings.automationAPIServerConfiguration
        if configuration != currentConfiguration {
            currentConfiguration = configuration
            if configuration.enabled {
                settings.ensureAutomationAPIToken()
                let refreshedConfiguration = settings.automationAPIServerConfiguration
                currentConfiguration = refreshedConfiguration
                serverState = "starting"
                server.start(port: refreshedConfiguration.port) { [weak self] request in
                    guard let self else {
                        return AutomationAPIHTTPResponse.error("Automation API is unavailable.", statusCode: 503)
                    }
                    return await self.handle(request: request)
                }
                CrashReporter.logInfo("Automation API listener requested on 127.0.0.1:\(refreshedConfiguration.port)")
            } else {
                server.stop()
                serverState = "disabled"
                CrashReporter.logInfo("Automation API listener stopped")
            }
        }

        applyCodexCloudMonitoring(using: settings)
        refreshCodexCLIStatus()

        Task {
            await refreshNotificationAuthorizationState()
            if configuration.enabled && settings.automationAPINotificationsEnabled {
                await requestNotificationPermissionIfNeeded()
            }
        }
    }

    func stop() {
        currentConfiguration = nil
        serverState = "disabled"
        server.stop()
        codexCloudMonitoringTask?.cancel()
        codexCloudMonitoringTask = nil
        codexCloudTaskTracker.reset()
        codexCloudStatusMessage = "Disabled"
    }

    func setNotificationInteractionHandler(_ handler: @escaping @MainActor (_ source: String?) -> Void) {
        notificationInteractionHandler = handler
    }

    func refreshNotificationAuthorizationState() async {
        let settings = await notificationCenter.notificationSettings()
        notificationAuthorizationState = Self.authorizationState(from: settings.authorizationStatus)
    }

    func requestNotificationPermissionIfNeeded() async {
        await refreshNotificationAuthorizationState()
        if notificationAuthorizationState == .denied {
            serverMessage = "Enable notifications for Open Assist in macOS Notification settings."
            return
        }
        guard notificationAuthorizationState == .notDetermined else { return }
        do {
            _ = try await notificationCenter.requestAuthorization(options: [.alert, .sound])
        } catch {
            CrashReporter.logError("Automation API notification permission request failed: \(error.localizedDescription)")
        }
        await refreshNotificationAuthorizationState()
    }

    func sendTestAnnouncement(channels: [AutomationAPIChannel]) async -> String {
        do {
            let response = try await deliver(
                AutomationAPIAnnounceRequest(
                    message: "This is an Open Assist automation test.",
                    title: "Open Assist",
                    subtitle: "Automation API",
                    channels: channels,
                    voiceIdentifier: nil,
                    sound: nil,
                    source: "openassist.settings-test",
                    dedupeKey: nil,
                    dedupeWindowSeconds: 0
                )
            )

            if response.accepted {
                return "Test sent."
            }
            return "Test skipped."
        } catch {
            return error.localizedDescription
        }
    }

    func maskedToken(for settings: SettingsStore) -> String {
        let token = settings.automationAPIToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count > 12 else {
            return token.isEmpty ? "No token yet" : token
        }
        return "\(token.prefix(6))••••\(token.suffix(4))"
    }

    func claudeNotificationCommandExample(for settings: SettingsStore) -> String {
        let port = Int(settings.automationAPIPort)
        let token = settings.automationAPIToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        curl -sS -X POST http://127.0.0.1:\(port)/automation/v1/hooks/claude -H 'Content-Type: application/json' -H 'Authorization: Bearer \(token)' --data @-
        """
    }

    func claudeNotificationHookExample(for settings: SettingsStore) -> String {
        let command = claudeNotificationCommandExample(for: settings)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        {
          "type": "command",
          "command": "\(command)"
        }
        """
    }

    func claudeHTTPHookExample(for settings: SettingsStore) -> String {
        let port = Int(settings.automationAPIPort)
        let token = settings.automationAPIToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        {
          "type": "http",
          "url": "http://127.0.0.1:\(port)/automation/v1/hooks/claude",
          "headers": {
            "Authorization": "Bearer \(token)"
          }
        }
        """
    }

    func codexCLINotifyExample(for settings: SettingsStore) -> String {
        let port = Int(settings.automationAPIPort)
        let token = settings.automationAPIToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        notify = ["sh", "-lc", "curl -sS -X POST http://127.0.0.1:\(port)/automation/v1/hooks/codex -H 'Content-Type: application/json' -H 'Authorization: Bearer \(token)' --data-binary \\\"$1\\\"", "openassist-codex"]
        """
    }

    private func handle(request: AutomationAPIHTTPRequest) async -> AutomationAPIHTTPResponse {
        do {
            switch (request.method, request.path) {
            case ("GET", "/automation/v1/health"):
                let response = await healthResponse()
                return .json(response)
            case ("POST", "/automation/v1/announce"):
                try validateAuthorization(for: request)
                let decoded = try decodeAnnounceRequest(from: request.body)
                let response = try await deliver(decoded)
                return .json(response)
            case ("POST", "/automation/v1/hooks/claude"):
                try validateAuthorization(for: request)
                let decoded = try ClaudeCodeHookAdapter.adapt(request.body)
                let response = try await deliver(decoded)
                return .json(response)
            case ("POST", "/automation/v1/hooks/codex"):
                try validateAuthorization(for: request)
                let decoded = try CodexNotifyHookAdapter.adapt(request.body)
                let response = try await deliver(decoded)
                return .json(response)
            case ("GET", _), ("POST", _):
                throw AutomationAPIRequestError.notFound
            default:
                throw AutomationAPIRequestError.methodNotAllowed
            }
        } catch let requestError as AutomationAPIRequestError {
            switch requestError {
            case .unauthorized:
                return .error(requestError.localizedDescription, statusCode: 401)
            case .forbidden:
                return .error(requestError.localizedDescription, statusCode: 403)
            case .invalidRequest, .unsupportedHookEvent:
                return .error(requestError.localizedDescription, statusCode: 422)
            case .notFound:
                return .error(requestError.localizedDescription, statusCode: 404)
            case .methodNotAllowed:
                return .error(requestError.localizedDescription, statusCode: 405)
            }
        } catch {
            CrashReporter.logError("Automation API request failed: \(error.localizedDescription)")
            return .error("Automation API request failed.", statusCode: 500)
        }
    }

    private func validateAuthorization(for request: AutomationAPIHTTPRequest) throws {
        guard let settings else {
            throw AutomationAPIRequestError.forbidden("Automation API settings are unavailable.")
        }

        guard AutomationAPIAuthorization.isAuthorized(
            authorizationHeader: request.headerValue(for: "authorization"),
            expectedToken: settings.automationAPIToken
        ) else {
            throw AutomationAPIRequestError.unauthorized
        }
    }

    private func decodeAnnounceRequest(from body: Data) throws -> AutomationAPIAnnounceRequest {
        do {
            return try JSONDecoder().decode(AutomationAPIAnnounceRequest.self, from: body)
        } catch {
            throw AutomationAPIRequestError.invalidRequest("Invalid announce request JSON payload.")
        }
    }

    private func healthResponse() async -> AutomationAPIHealthResponse {
        await refreshNotificationAuthorizationState()

        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedVoice = settings?.automationAPIDefaultVoiceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedSound = settings?.automationAPIDefaultSound ?? .processing
        let port = Int(currentConfiguration?.port ?? settings?.automationAPIPort ?? 0)
        let channels = settings?.automationAPIEnabledChannels ?? []
        let selectedVoiceOption = availableVoices.first { voice in
            voice.id == selectedVoice
        }

        return AutomationAPIHealthResponse.make(
            serverState: serverState,
            version: version?.isEmpty == false ? version! : "unknown",
            bindAddress: "127.0.0.1",
            port: port,
            enabledChannels: channels,
            notificationPermission: notificationAuthorizationState,
            selectedVoice: selectedVoiceOption,
            selectedSound: selectedSound
        )
    }

    private func deliver(_ request: AutomationAPIAnnounceRequest) async throws -> AutomationAPIActionResponse {
        let requestID = UUID().uuidString
        let now = Date()
        let announcement = try resolvedAnnouncement(from: request)
        if dedupeStore.shouldDedupe(
            key: announcement.dedupeKey,
            now: now,
            windowSeconds: announcement.dedupeWindowSeconds
        ) {
            return AutomationAPIActionResponse(
                requestId: requestID,
                accepted: true,
                deliveredChannels: [],
                deduped: true,
                receivedAt: iso8601String(from: now)
            )
        }

        var deliveredChannels: [AutomationAPIChannel] = []
        let deliverableChannels = try await filterDeliverableChannels(for: announcement.channels)

        if deliverableChannels.contains(.notification) {
            try await deliverNotification(for: announcement)
            deliveredChannels.append(.notification)
        }

        if deliverableChannels.contains(.speech) {
            deliverSpeech(for: announcement)
            deliveredChannels.append(.speech)
        }

        if deliverableChannels.contains(.sound) {
            deliverSound(for: announcement.sound)
            deliveredChannels.append(.sound)
        }

        return AutomationAPIActionResponse(
            requestId: requestID,
            accepted: !deliveredChannels.isEmpty,
            deliveredChannels: deliveredChannels,
            deduped: false,
            receivedAt: iso8601String(from: now)
        )
    }

    private func resolvedAnnouncement(from request: AutomationAPIAnnounceRequest) throws -> AutomationAPIResolvedAnnouncement {
        guard let settings else {
            throw AutomationAPIRequestError.forbidden("Automation API settings are unavailable.")
        }

        let message = collapseWhitespace(request.message)
        guard !message.isEmpty else {
            throw AutomationAPIRequestError.invalidRequest("Announce request requires message.")
        }

        let requestedChannels = request.channels?.isEmpty == false
            ? request.channels ?? []
            : settings.automationAPIEnabledChannels

        guard !requestedChannels.isEmpty else {
            throw AutomationAPIRequestError.forbidden("No automation delivery channels are enabled.")
        }

        let title = collapseWhitespace(request.title).isEmpty ? "Open Assist" : collapseWhitespace(request.title)
        let subtitle = collapseWhitespace(request.subtitle)
        let source = collapseWhitespace(request.source).isEmpty ? "automation-api" : collapseWhitespace(request.source)
        let enabledSources = Set(
            AutomationAPISource.allCases.filter { settings.isAutomationSourceEnabled($0) }
        )
        try AutomationAPISourceGate.validate(
            sourceIdentifier: source,
            enabledSources: enabledSources
        )
        let voiceIdentifier = collapseWhitespace(request.voiceIdentifier)
        let dedupeWindowSeconds = min(300, max(0, request.dedupeWindowSeconds ?? 15))
        let sound = request.sound ?? settings.automationAPIDefaultSound
        let filteredChannels = sound == .none
            ? requestedChannels.filter { $0 != .sound }
            : requestedChannels

        guard !filteredChannels.isEmpty else {
            throw AutomationAPIRequestError.invalidRequest(
                "No deliverable channels remain after applying request overrides."
            )
        }

        return AutomationAPIResolvedAnnouncement(
            message: message,
            title: title,
            subtitle: subtitle.isEmpty ? nil : subtitle,
            channels: filteredChannels,
            voiceIdentifier: voiceIdentifier.isEmpty ? settings.automationAPIDefaultVoiceIdentifierOrNil : voiceIdentifier,
            sound: sound,
            source: source,
            dedupeKey: collapseWhitespace(request.dedupeKey).isEmpty ? nil : collapseWhitespace(request.dedupeKey),
            dedupeWindowSeconds: dedupeWindowSeconds
        )
    }

    private func filterDeliverableChannels(
        for requestedChannels: [AutomationAPIChannel]
    ) async throws -> [AutomationAPIChannel] {
        guard let settings else {
            throw AutomationAPIRequestError.forbidden("Automation API settings are unavailable.")
        }

        let enabled = Set(settings.automationAPIEnabledChannels)
        let disabledRequested = requestedChannels.filter { !enabled.contains($0) }
        guard disabledRequested.isEmpty else {
            throw AutomationAPIRequestError.forbidden("Requested automation channel is disabled in Settings.")
        }
        let requested = requestedChannels.filter { enabled.contains($0) }
        guard !requested.isEmpty else {
            throw AutomationAPIRequestError.forbidden("No automation delivery channels are enabled.")
        }

        await refreshNotificationAuthorizationState()

        let permittedChannels = AutomationAPIRequestResolver.notificationPermittedChannels(
            from: requested,
            notificationAuthorizationState: notificationAuthorizationState
        )
        if permittedChannels.isEmpty, requested.contains(.notification) {
            throw AutomationAPIRequestError.forbidden("Desktop notifications need macOS notification permission.")
        }
        return permittedChannels
    }

    private func deliverNotification(for announcement: AutomationAPIResolvedAnnouncement) async throws {
        let content = UNMutableNotificationContent()
        content.title = announcement.title
        content.body = announcement.message
        if let subtitle = announcement.subtitle {
            content.subtitle = subtitle
        }
        content.userInfo = [
            Self.automationNotificationUserInfoKey: true,
            "source": announcement.source
        ]
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "\(Self.automationNotificationIdentifierPrefix)\(UUID().uuidString)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        )
        try await notificationCenter.add(request)
    }

    private func deliverSpeech(for announcement: AutomationAPIResolvedAnnouncement) {
        let utterance = AVSpeechUtterance(
            string: [announcement.title, announcement.subtitle, announcement.message]
                .compactMap { $0 }
                .joined(separator: ". ")
        )
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        if let voiceIdentifier = announcement.voiceIdentifier,
           let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            utterance.voice = voice
        }
        utterance.rate = 0.45
        speechSynthesizer.speak(utterance)
    }

    private func deliverSound(for sound: AutomationAPISound) {
        guard let settings else { return }
        guard sound != .none else { return }

        let soundName: String
        switch sound {
        case .startListening:
            soundName = settings.dictationStartSoundName
        case .processing:
            soundName = settings.dictationProcessingSoundName
        case .pasted:
            soundName = settings.dictationPastedSoundName
        case .correctionLearned:
            soundName = settings.dictationCorrectionLearnedSoundName
        case .none:
            soundName = SettingsStore.noDictationSoundName
        }

        guard soundName != SettingsStore.noDictationSoundName,
              let nsSound = NSSound(named: NSSound.Name(soundName)) else {
            return
        }
        nsSound.volume = Float(settings.dictationFeedbackVolume)
        nsSound.play()
    }

    private func refreshAvailableVoices() {
        availableVoices = [
            AutomationAPIVoiceOption(id: "", name: "System Default", language: "")
        ] + AVSpeechSynthesisVoice.speechVoices()
            .map {
                AutomationAPIVoiceOption(
                    id: $0.identifier,
                    name: $0.name,
                    language: $0.language
                )
            }
            .sorted { lhs, rhs in
                lhs.displayLabel.localizedCaseInsensitiveCompare(rhs.displayLabel) == .orderedAscending
            }
    }

    private static func authorizationState(from status: UNAuthorizationStatus) -> AutomationAPINotificationAuthorizationState {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .authorized:
            return .authorized
        case .provisional:
            return .provisional
        case .ephemeral:
            return .ephemeral
        @unknown default:
            return .unknown
        }
    }

    private func collapseWhitespace(_ value: String?) -> String {
        guard let value else { return "" }
        return value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func iso8601String(from date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func refreshCodexCLIStatus() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let version = try await codexCommandRunner.codexVersion()
                self.codexCLIStatusMessage = "Installed: \(version)"
            } catch let error as CodexCommandError {
                self.codexCLIStatusMessage = error.localizedDescription
            } catch {
                self.codexCLIStatusMessage = error.localizedDescription
            }
        }
    }

    private func applyCodexCloudMonitoring(using settings: SettingsStore) {
        guard settings.automationCodexCloudEnabled else {
            codexCloudMonitoringTask?.cancel()
            codexCloudMonitoringTask = nil
            codexCloudTaskTracker.reset()
            codexCloudStatusMessage = "Disabled"
            lastCodexCloudLoggedError = nil
            return
        }

        guard codexCloudMonitoringTask == nil else { return }

        codexCloudTaskTracker.reset()
        codexCloudStatusMessage = "Starting Codex Cloud beta monitoring…"
        lastCodexCloudLoggedError = nil

        codexCloudMonitoringTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.pollCodexCloudOnce()
                do {
                    try await Task.sleep(nanoseconds: Self.codexCloudPollIntervalNanoseconds)
                } catch {
                    break
                }
            }
        }
    }

    private func pollCodexCloudOnce() async {
        do {
            let tasks = try await codexCommandRunner.listCloudTasks(limit: 20)
            codexCloudStatusMessage = tasks.isEmpty
                ? "Watching Codex Cloud tasks every 60 seconds."
                : "Watching \(tasks.count) recent Codex Cloud tasks every 60 seconds."
            lastCodexCloudLoggedError = nil

            let events = codexCloudTaskTracker.ingest(tasks)
            guard !events.isEmpty else { return }

            for event in events {
                let request = try await codexCloudAnnouncementRequest(for: event)
                _ = try await deliver(request)
            }
        } catch let error as CodexCommandError {
            codexCloudStatusMessage = error.localizedDescription
            logCodexCloudErrorIfNeeded(error.localizedDescription)
        } catch {
            codexCloudStatusMessage = error.localizedDescription
            logCodexCloudErrorIfNeeded(error.localizedDescription)
        }
    }

    private func codexCloudAnnouncementRequest(
        for event: CodexCloudAnnouncementEvent
    ) async throws -> AutomationAPIAnnounceRequest {
        let task = event.task
        let taskStatus = try? await codexCommandRunner.cloudTaskStatus(taskID: task.id)

        let title = "Codex Cloud"
        let subtitle = event.outcome == .ready ? "Task ready" : "Task failed"
        let message: String

        switch event.outcome {
        case .ready:
            message = codexCloudReadyMessage(task: task, status: taskStatus)
        case .failed:
            message = codexCloudFailureMessage(task: task, status: taskStatus)
        }

        return AutomationAPIAnnounceRequest(
            message: message,
            title: title,
            subtitle: subtitle,
            channels: nil,
            voiceIdentifier: nil,
            sound: nil,
            source: "codex-cloud.\(event.outcome.rawValue)",
            dedupeKey: "codex-cloud:\(task.id):\(event.outcome.rawValue)",
            dedupeWindowSeconds: 120
        )
    }

    private func codexCloudReadyMessage(
        task: CodexCloudTask,
        status: CodexCloudTaskStatusResponse?
    ) -> String {
        let title = status?.trimmedTitle.isEmpty == false ? status!.trimmedTitle : task.trimmedTitle
        let description = status?.trimmedDescription.isEmpty == false
            ? status!.trimmedDescription
            : task.trimmedDescription

        if !description.isEmpty {
            return collapseWhitespace(description)
        }

        if !title.isEmpty, let filesChanged = status?.summary?.filesChanged ?? task.summary?.filesChanged, filesChanged > 0 {
            return "\"\(title)\" is ready with changes in \(filesChanged) file\(filesChanged == 1 ? "" : "s")."
        }

        if !title.isEmpty {
            return "\"\(title)\" is ready."
        }

        return "A Codex Cloud task is ready."
    }

    private func codexCloudFailureMessage(
        task: CodexCloudTask,
        status: CodexCloudTaskStatusResponse?
    ) -> String {
        let errorMessage = status?.trimmedErrorMessage.isEmpty == false
            ? status!.trimmedErrorMessage
            : task.trimmedErrorMessage
        if !errorMessage.isEmpty {
            return collapseWhitespace(errorMessage)
        }

        let description = status?.trimmedDescription.isEmpty == false
            ? status!.trimmedDescription
            : task.trimmedDescription
        if !description.isEmpty {
            return collapseWhitespace(description)
        }

        let title = status?.trimmedTitle.isEmpty == false ? status!.trimmedTitle : task.trimmedTitle
        if !title.isEmpty {
            return "\"\(title)\" failed."
        }

        return "A Codex Cloud task failed."
    }

    private func logCodexCloudErrorIfNeeded(_ message: String) {
        guard lastCodexCloudLoggedError != message else { return }
        lastCodexCloudLoggedError = message
        CrashReporter.logWarning("Codex Cloud monitoring: \(message)")
    }

    private func isAutomationNotification(_ response: UNNotificationResponse) -> Bool {
        if response.notification.request.identifier.hasPrefix(Self.automationNotificationIdentifierPrefix) {
            return true
        }
        return response.notification.request.content.userInfo[Self.automationNotificationUserInfoKey] as? Bool == true
    }

    private func handleAutomationNotificationInteraction(source _: String?) {
        // Ignore notification clicks for automation notifications.
    }
}

extension AutomationAPICoordinator: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await MainActor.run {
            guard self.isAutomationNotification(response) else { return }
            let source = response.notification.request.content.userInfo["source"] as? String
            self.handleAutomationNotificationInteraction(source: source)
        }
    }
}
