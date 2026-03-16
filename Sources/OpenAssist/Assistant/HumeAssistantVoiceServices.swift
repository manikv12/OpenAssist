import AVFoundation
import Foundation
import Hume
import OpenAssistObjCInterop

enum AssistantHumeVoiceSource: String, CaseIterable, Codable, Identifiable, Sendable {
    case customVoice = "CUSTOM_VOICE"
    case humeAI = "HUME_AI"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .customVoice:
            return "My Voices"
        case .humeAI:
            return "Hume Voice Library"
        }
    }

    var ttsProvider: TTSVoiceProvider {
        switch self {
        case .customVoice:
            return .customVoice
        case .humeAI:
            return .humeAi
        }
    }
}

struct AssistantHumeVoiceOption: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let source: AssistantHumeVoiceSource
    let compatibleOctaveModels: [String]

    var displayLabel: String {
        "\(name) (\(source.displayName))"
    }
}

enum AssistantHumeConversationPhase: String, Sendable {
    case disconnected
    case connecting
    case connected
    case speaking
}

struct AssistantHumeConversationSnapshot: Equatable, Sendable {
    var phase: AssistantHumeConversationPhase = .disconnected
    var isMicrophoneMuted = false
    var isAssistantPaused = false
    var lastError: String?
    var chatGroupID: String?

    var allowsMicrophoneStreaming: Bool {
        guard !isMicrophoneMuted else { return false }
        return phase == .connected
    }
}

enum HumeAssistantVoiceError: LocalizedError {
    case missingCredentials
    case missingVoiceSelection
    case invalidResponse
    case configurationUnavailable(String)
    case conversationUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "Enter your Hume API key and Secret key first."
        case .missingVoiceSelection:
            return "Choose a Hume voice before using Hume voice output."
        case .invalidResponse:
            return "Hume returned a response Open Assist could not read."
        case .configurationUnavailable(let message):
            return message
        case .conversationUnavailable(let message):
            return message
        }
    }
}

enum AssistantHumeDefaults {
    static let apiHost = "api.hume.ai"
    static let ttsTimeout: TimeInterval = 30
    static let tokenRefreshSkew: TimeInterval = 60
    static let conversationSampleRate = 48_000
    static let conversationChannels = 1
    static let conversationConfigName = "Open Assist Voice Conversation"
    static let conversationPrompt = """
    You are Open Assist Voice, a helpful live conversation mode inside Open Assist on macOS.
    Speak clearly, briefly, and naturally.
    Keep answers practical and easy to understand.
    Do not claim to run local coding tools or terminal commands.
    Keep replies short so the user can answer naturally between turns.
    """
    static let speechRate = 0.45
}

@MainActor
final class HumeAccessTokenService {
    private let settings: SettingsStore
    private let session: URLSession
    private var cachedToken: String?
    private var cachedExpiry: Date?

    init(settings: SettingsStore, session: URLSession = .shared) {
        self.settings = settings
        self.session = session
    }

    func currentAccessToken(forceRefresh: Bool = false) async throws -> String {
        let apiKey = settings.assistantHumeAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let secretKey = settings.assistantHumeSecretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty, !secretKey.isEmpty else {
            throw HumeAssistantVoiceError.missingCredentials
        }

        if !forceRefresh,
           let cachedToken,
           let cachedExpiry,
           cachedExpiry.timeIntervalSinceNow > AssistantHumeDefaults.tokenRefreshSkew {
            return cachedToken
        }

        var request = URLRequest(url: URL(string: "https://\(AssistantHumeDefaults.apiHost)/oauth2-cc/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Basic \(Data("\(apiKey):\(secretKey)".utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        request.httpBody = "grant_type=client_credentials".data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AssistantSpeechError.serviceUnavailable("Hume token request returned an invalid response.")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .assistantNonEmpty
                ?? "Hume token request failed with status \(httpResponse.statusCode)."
            throw AssistantSpeechError.serviceUnavailable(message)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let payload = try decoder.decode(HumeAccessTokenResponse.self, from: data)
        cachedToken = payload.accessToken
        if let expiresIn = payload.expiresIn {
            cachedExpiry = Date().addingTimeInterval(expiresIn)
        } else {
            cachedExpiry = Date().addingTimeInterval(15 * 60)
        }
        return payload.accessToken
    }

    func reset() {
        cachedToken = nil
        cachedExpiry = nil
    }
}

@MainActor
final class HumeVoiceCatalogService {
    private let settings: SettingsStore
    private let session: URLSession

    init(settings: SettingsStore, session: URLSession = .shared) {
        self.settings = settings
        self.session = session
    }

    func listVoices(source: AssistantHumeVoiceSource) async throws -> [AssistantHumeVoiceOption] {
        let apiKey = settings.assistantHumeAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw HumeAssistantVoiceError.missingCredentials
        }

        var pageNumber = 0
        var collected: [AssistantHumeVoiceOption] = []
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        while true {
            var components = URLComponents(string: "https://\(AssistantHumeDefaults.apiHost)/v0/tts/voices")!
            components.queryItems = [
                URLQueryItem(name: "provider", value: source.rawValue),
                URLQueryItem(name: "page_number", value: String(pageNumber)),
                URLQueryItem(name: "page_size", value: "100")
            ]

            var request = URLRequest(url: components.url!)
            request.httpMethod = "GET"
            request.timeoutInterval = 20
            request.setValue(apiKey, forHTTPHeaderField: "X-Hume-Api-Key")

            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw AssistantSpeechError.serviceUnavailable("Hume voice list returned an invalid response.")
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                let message = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .assistantNonEmpty
                    ?? "Hume voice list failed with status \(httpResponse.statusCode)."
                throw AssistantSpeechError.serviceUnavailable(message)
            }

            let payload = try decoder.decode(HumePagedVoicesResponse.self, from: data)
            collected.append(contentsOf: payload.voicesPage.map { voice in
                AssistantHumeVoiceOption(
                    id: voice.id,
                    name: voice.name,
                    source: AssistantHumeVoiceSource(rawValue: voice.provider) ?? source,
                    compatibleOctaveModels: voice.compatibleOctaveModels ?? []
                )
            })

            pageNumber += 1
            if pageNumber >= payload.totalPages {
                break
            }
        }

        return collected.sorted {
            $0.displayLabel.localizedCaseInsensitiveCompare($1.displayLabel) == .orderedAscending
        }
    }
}

struct HumeConversationConfigReference: Equatable, Sendable {
    let id: String
    let version: Int
}

@MainActor
final class HumeConversationConfigService {
    private let settings: SettingsStore
    private let session: URLSession

    init(settings: SettingsStore, session: URLSession = .shared) {
        self.settings = settings
        self.session = session
    }

    func ensureConversationConfig() async throws -> HumeConversationConfigReference {
        let apiKey = settings.assistantHumeAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw HumeAssistantVoiceError.missingCredentials
        }
        guard let selectedVoice = selectedVoiceReference() else {
            throw HumeAssistantVoiceError.missingVoiceSelection
        }

        let requestBody = HumeConfigRequest(
            name: AssistantHumeDefaults.conversationConfigName,
            eviVersion: "3",
            prompt: .init(text: AssistantHumeDefaults.conversationPrompt),
            voice: selectedVoice,
            versionDescription: "Managed by Open Assist"
        )

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        if let existingConfigID = settings.assistantHumeConversationConfigID.assistantNonEmpty {
            let url = URL(string: "https://\(AssistantHumeDefaults.apiHost)/v0/evi/configs/\(existingConfigID)")!
            let response = try await sendConfigRequest(
                url: url,
                method: "POST",
                apiKey: apiKey,
                requestBody: requestBody,
                decoder: decoder
            )
            let resolvedID = response.id?.assistantNonEmpty ?? existingConfigID
            let resolvedVersion = response.version ?? max(1, settings.assistantHumeConversationConfigVersion)
            settings.assistantHumeConversationConfigID = resolvedID
            settings.assistantHumeConversationConfigVersion = resolvedVersion
            return HumeConversationConfigReference(id: resolvedID, version: resolvedVersion)
        }

        let url = URL(string: "https://\(AssistantHumeDefaults.apiHost)/v0/evi/configs")!
        let response = try await sendConfigRequest(
            url: url,
            method: "POST",
            apiKey: apiKey,
            requestBody: requestBody,
            decoder: decoder
        )
        guard let configID = response.id?.assistantNonEmpty,
              let version = response.version else {
            throw HumeAssistantVoiceError.configurationUnavailable("Hume created a config, but did not return a usable config ID.")
        }
        settings.assistantHumeConversationConfigID = configID
        settings.assistantHumeConversationConfigVersion = version
        return HumeConversationConfigReference(id: configID, version: version)
    }

    private func selectedVoiceReference() -> HumeVoiceReference? {
        guard let voiceID = settings.assistantHumeVoiceID.assistantNonEmpty else {
            return nil
        }
        return HumeVoiceReference(
            id: voiceID,
            provider: settings.assistantHumeVoiceSource.rawValue
        )
    }

    private func sendConfigRequest(
        url: URL,
        method: String,
        apiKey: String,
        requestBody: HumeConfigRequest,
        decoder: JSONDecoder
    ) async throws -> HumeConfigResponse {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue(apiKey, forHTTPHeaderField: "X-Hume-Api-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HumeAssistantVoiceError.configurationUnavailable("Hume configuration request returned an invalid response.")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .assistantNonEmpty
                ?? "Hume configuration request failed with status \(httpResponse.statusCode)."
            throw HumeAssistantVoiceError.configurationUnavailable(message)
        }
        return try decoder.decode(HumeConfigResponse.self, from: data)
    }
}

final class HumeConversationService {
    var onSnapshotChange: ((AssistantHumeConversationSnapshot) -> Void)?
    var onStatusMessage: ((String?) -> Void)?

    private let settings: SettingsStore
    private let tokenService: HumeAccessTokenService
    private let configService: HumeConversationConfigService
    private let session: URLSession
    private var client: HumeClient?
    private var socket: StreamSocket?
    private var listenerTask: Task<Void, Never>?
    private var audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let audioControlQueue = DispatchQueue(label: "OpenAssist.HumeConversation.AudioControl")
    private let converterLock = NSLock()
    private var playerFormat: AVAudioFormat?
    private var isPlayerNodeConnected = false
    private var converter: AVAudioConverter?
    private var converterInputSignature: String?
    private var snapshot = AssistantHumeConversationSnapshot() {
        didSet {
            onSnapshotChange?(snapshot)
        }
    }
    private var hasInstalledInputTap = false
    private var pausedByUser = false
    private var currentCustomSessionID = UUID().uuidString
    private let sendQueue = DispatchQueue(label: "OpenAssist.HumeConversation.SendQueue")

    init(
        settings: SettingsStore,
        tokenService: HumeAccessTokenService,
        configService: HumeConversationConfigService,
        session: URLSession = .shared
    ) {
        self.settings = settings
        self.tokenService = tokenService
        self.configService = configService
        self.session = session
        audioEngine.attach(playerNode)
    }

    var currentSnapshot: AssistantHumeConversationSnapshot { snapshot }

    func startConversation() async {
        guard snapshot.phase == .disconnected else { return }

        do {
            snapshot.phase = .connecting
            snapshot.lastError = nil
            onStatusMessage?(nil)
            pausedByUser = false
            currentCustomSessionID = UUID().uuidString
            let config = try await configService.ensureConversationConfig()
            let tokenService = self.tokenService
            let humeClient = HumeClient(options: .accessTokenProvider {
                try await tokenService.currentAccessToken()
            })
            client = humeClient

            let streamSocket = try await humeClient.empathicVoice.chat.connect(
                with: ChatConnectOptions(
                    configId: config.id,
                    configVersion: String(config.version),
                    resumedChatGroupId: nil,
                    voiceId: settings.assistantHumeVoiceID.assistantNonEmpty,
                    verboseTranscription: true,
                    eventLimit: nil
                ),
                onOpen: { [weak self] _ in
                    Task { @MainActor [weak self] in
                        await self?.sendInitialSessionSettings()
                    }
                },
                onClose: { [weak self] _, reason in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if let reason = reason?.assistantNonEmpty {
                            self.snapshot.lastError = reason
                            self.onStatusMessage?(reason)
                        }
                        await self.endConversation()
                    }
                },
                onError: { [weak self] error, _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.snapshot.lastError = error.localizedDescription
                        self.onStatusMessage?(error.localizedDescription)
                    }
                }
            )
            socket = streamSocket
            listenerTask = Task { [weak self] in
                await self?.listenForEvents()
            }
        } catch {
            snapshot.phase = .disconnected
            snapshot.lastError = error.localizedDescription
            onStatusMessage?(error.localizedDescription)
        }
    }

    func endConversation() async {
        listenerTask?.cancel()
        listenerTask = nil
        socket = nil
        stopAudioEngine()
        clearPlaybackQueue()
        client = nil
        pausedByUser = false
        snapshot.phase = .disconnected
        snapshot.isAssistantPaused = false
        snapshot.chatGroupID = nil
    }

    func toggleMicrophoneMute() {
        snapshot.isMicrophoneMuted.toggle()
        onStatusMessage?(snapshot.isMicrophoneMuted ? "Microphone muted." : "Microphone live.")
    }

    func stopSpeaking() async {
        guard let socket else { return }
        do {
            try await socket.pauseAssistant(message: PauseAssistantMessage(customSessionId: currentCustomSessionID))
            pausedByUser = true
            snapshot.isAssistantPaused = true
            clearPlaybackQueue()
            if snapshot.phase == .speaking {
                snapshot.phase = .connected
            }
            onStatusMessage?("Assistant speech stopped.")
        } catch {
            snapshot.lastError = error.localizedDescription
            onStatusMessage?(error.localizedDescription)
        }
    }

    private func sendInitialSessionSettings() async {
        guard let socket else { return }

        do {
            try await socket.sendSessionSettings(
                message: SessionSettings(
                    audio: AudioConfiguration(
                        channels: AssistantHumeDefaults.conversationChannels,
                        encoding: .linear16,
                        sampleRate: AssistantHumeDefaults.conversationSampleRate
                    ),
                    builtinTools: nil,
                    context: nil,
                    customSessionId: currentCustomSessionID,
                    languageModelApiKey: nil,
                    systemPrompt: nil,
                    tools: nil,
                    variables: nil,
                    voiceId: settings.assistantHumeVoiceID.assistantNonEmpty
                )
            )
        } catch {
            snapshot.lastError = error.localizedDescription
            onStatusMessage?(error.localizedDescription)
        }
    }

    private func listenForEvents() async {
        guard let socket else { return }

        do {
            for try await event in socket.receive() {
                if Task.isCancelled { return }
                await handle(event)
            }
        } catch {
            snapshot.lastError = error.localizedDescription
            onStatusMessage?(error.localizedDescription)
            await endConversation()
        }
    }

    private func handle(_ event: SubscribeEvent) async {
        switch event {
        case .chatMetadata(let metadata):
            snapshot.phase = .connected
            snapshot.chatGroupID = metadata.chatGroupId
            do {
                try startAudioEngineIfNeeded()
            } catch {
                snapshot.lastError = error.localizedDescription
                onStatusMessage?(error.localizedDescription)
                await endConversation()
            }
        case .audioOutput(let audioOutput):
            do {
                try enqueueAudioOutput(audioOutput)
                snapshot.phase = .speaking
            } catch {
                snapshot.lastError = error.localizedDescription
                onStatusMessage?(error.localizedDescription)
            }
        case .assistantEnd:
            clearPlaybackQueue()
            snapshot.phase = .connected
            snapshot.isAssistantPaused = false
            pausedByUser = false
        case .userInterruption:
            clearPlaybackQueue()
            snapshot.phase = .connected
        case .webSocketError(let error):
            snapshot.lastError = error.message.assistantNonEmpty ?? error.slug.assistantNonEmpty ?? "Hume conversation error."
            onStatusMessage?(snapshot.lastError)
        default:
            break
        }
    }

    private func startAudioEngineIfNeeded() throws {
        try audioControlQueue.sync {
            try startAudioEngineIfNeededLocked()
        }
    }

    private func stopAudioEngine() {
        audioControlQueue.sync {
            stopAudioEngineLocked()
        }
    }

    private func sendAudioChunk(_ audioData: Data) async {
        guard snapshot.allowsMicrophoneStreaming,
              let socket,
              snapshot.phase == .connected else {
            return
        }

        do {
            if pausedByUser {
                try await socket.resumeAssistant(message: ResumeAssistantMessage(customSessionId: currentCustomSessionID))
                pausedByUser = false
                snapshot.isAssistantPaused = false
            }

            try await socket.sendAudioInput(
                message: AudioInput(
                    customSessionId: currentCustomSessionID,
                    data: audioData.base64EncodedString()
                )
            )
        } catch {
            snapshot.lastError = error.localizedDescription
            onStatusMessage?(error.localizedDescription)
        }
    }

    private func enqueueAudioOutput(_ audioOutput: AudioOutput) throws {
        try audioControlQueue.sync {
            try enqueueAudioOutputLocked(audioOutput)
        }
    }

    private func clearPlaybackQueue() {
        audioControlQueue.sync {
            clearPlaybackQueueLocked()
        }
    }

    private func resolvedPlaybackFormat(for header: HumeWaveHeader?) throws -> AVAudioFormat {
        if let header,
           let format = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: Double(header.sampleRate),
                channels: AVAudioChannelCount(header.channelCount),
                interleaved: true
           ) {
            return format
        }

        guard let fallback = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(AssistantHumeDefaults.conversationSampleRate),
            channels: 1,
            interleaved: true
        ) else {
            throw HumeAssistantVoiceError.invalidResponse
        }
        return fallback
    }

    private func convertInput(
        buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        outputFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }

        var conversionError: NSError?
        var didProvideInput = false

        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        converter.convert(to: outputBuffer, error: &conversionError, withInputFrom: inputBlock)
        return conversionError == nil ? outputBuffer : nil
    }

    private func makePCMData(from buffer: AVAudioPCMBuffer) -> Data? {
        guard let channelData = buffer.int16ChannelData else { return nil }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return nil }
        return Data(bytes: channelData[0], count: frameLength * MemoryLayout<Int16>.size)
    }

    private func startAudioEngineIfNeededLocked() throws {
        if playerNode.engine == nil {
            audioEngine.attach(playerNode)
        }

        let inputNode = audioEngine.inputNode
        if !hasInstalledInputTap {
            let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: Double(AssistantHumeDefaults.conversationSampleRate),
                channels: AVAudioChannelCount(AssistantHumeDefaults.conversationChannels),
                interleaved: true
            )
            guard let targetFormat else {
                throw HumeAssistantVoiceError.conversationUnavailable("Could not prepare the microphone format for Hume conversation.")
            }

            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
                guard let self else { return }

                self.converterLock.lock()
                let activeConverter: AVAudioConverter?
                defer { self.converterLock.unlock() }

                let inputSignature = "\(buffer.format.sampleRate)-\(buffer.format.channelCount)-\(buffer.format.commonFormat.rawValue)-\(buffer.format.isInterleaved)"
                if self.converter == nil || self.converterInputSignature != inputSignature {
                    self.converter = AVAudioConverter(from: buffer.format, to: targetFormat)
                    self.converterInputSignature = inputSignature
                }
                activeConverter = self.converter

                guard let activeConverter,
                      let convertedBuffer = self.convertInput(buffer: buffer, converter: activeConverter, outputFormat: targetFormat),
                      let audioData = self.makePCMData(from: convertedBuffer) else {
                    return
                }

                self.sendQueue.async { [weak self] in
                    guard let self else { return }
                    Task { @MainActor [weak self] in
                        await self?.sendAudioChunk(audioData)
                    }
                }
            }
            hasInstalledInputTap = true
        }

        if !audioEngine.isRunning {
            if playerFormat == nil,
               let outputFormat = AVAudioFormat(
                    commonFormat: .pcmFormatInt16,
                    sampleRate: Double(AssistantHumeDefaults.conversationSampleRate),
                    channels: 1,
                    interleaved: true
               ) {
                try configurePlayerNodeLocked(for: outputFormat)
            }
            audioEngine.prepare()
            try audioEngine.start()
        }
    }

    private func stopAudioEngineLocked() {
        if hasInstalledInputTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInstalledInputTap = false
        }

        stopAndResetPlayerIgnoringFailures()

        if audioEngine.isRunning {
            audioEngine.stop()
        }

        converterLock.lock()
        converter = nil
        converterInputSignature = nil
        converterLock.unlock()

        playerFormat = nil
        if isPlayerNodeConnected {
            performObjectiveCAudioCleanup {
                self.audioEngine.disconnectNodeOutput(self.playerNode)
            }
            isPlayerNodeConnected = false
        }
    }

    private func enqueueAudioOutputLocked(_ audioOutput: AudioOutput) throws {
        guard !pausedByUser else { return }
        guard let rawData = Data(base64Encoded: audioOutput.data), !rawData.isEmpty else {
            throw HumeAssistantVoiceError.invalidResponse
        }

        if !audioEngine.isRunning {
            try startAudioEngineIfNeededLocked()
        }

        let header = HumeWaveHeader(data: rawData)
        let format = try resolvedPlaybackFormat(for: header)
        try configurePlayerNodeLocked(for: format)

        let audioBytes = header?.headerSize ?? 0 < rawData.count
            ? rawData.dropFirst(header?.headerSize ?? 0)
            : rawData[rawData.startIndex..<rawData.endIndex]
        guard !audioBytes.isEmpty else { return }

        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        let frameCount = AVAudioFrameCount(audioBytes.count / max(1, bytesPerFrame))
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return
        }

        buffer.frameLength = frameCount
        audioBytes.withUnsafeBytes { srcBuffer in
            guard let baseAddress = srcBuffer.baseAddress,
                  let channelData = buffer.int16ChannelData else {
                return
            }
            memcpy(channelData[0], baseAddress, Int(audioBytes.count))
        }

        try performObjectiveCAudioOperation("Queue assistant audio") {
            self.playerNode.scheduleBuffer(buffer, completionHandler: nil)
        }
        try startPlayerIfNeededLocked()
    }

    private func clearPlaybackQueueLocked() {
        stopAndResetPlayerIgnoringFailures()
    }

    private func configurePlayerNodeLocked(for format: AVAudioFormat) throws {
        let requiresReconnect =
            !isPlayerNodeConnected ||
            playerFormat?.sampleRate != format.sampleRate ||
            playerFormat?.channelCount != format.channelCount
        guard requiresReconnect else { return }

        stopAndResetPlayerIgnoringFailures()

        if isPlayerNodeConnected {
            try performObjectiveCAudioOperation("Reset assistant audio output") {
                self.audioEngine.disconnectNodeOutput(self.playerNode)
            }
            isPlayerNodeConnected = false
        }

        try performObjectiveCAudioOperation("Prepare assistant audio output") {
            self.audioEngine.connect(self.playerNode, to: self.audioEngine.mainMixerNode, format: format)
        }
        playerFormat = format
        isPlayerNodeConnected = true
    }

    private func startPlayerIfNeededLocked() throws {
        guard audioEngine.isRunning else { return }
        guard isPlayerNodeConnected else { return }
        guard !playerNode.isPlaying else { return }

        try performObjectiveCAudioOperation("Start assistant audio playback") {
            self.playerNode.play()
        }
    }

    private func stopAndResetPlayerIgnoringFailures() {
        performObjectiveCAudioCleanup {
            self.playerNode.stop()
        }
        performObjectiveCAudioCleanup {
            self.playerNode.reset()
        }
    }

    private func performObjectiveCAudioOperation(_ operation: String, _ block: @escaping () -> Void) throws {
        do {
            try OpenAssistObjCExceptionCatcher.perform(block)
        } catch {
            let detail = (error as NSError).localizedDescription.assistantNonEmpty
                ?? "\(operation) failed because macOS audio entered an invalid state."
            throw HumeAssistantVoiceError.conversationUnavailable(detail)
        }
    }

    private func performObjectiveCAudioCleanup(_ block: @escaping () -> Void) {
        try? OpenAssistObjCExceptionCatcher.perform(block)
    }
}

private struct HumeAccessTokenResponse: Decodable {
    let accessToken: String
    let expiresIn: TimeInterval?
}

private struct HumePagedVoicesResponse: Decodable {
    let pageNumber: Int
    let pageSize: Int
    let totalPages: Int
    let voicesPage: [HumeVoiceResponse]
}

private struct HumeVoiceResponse: Decodable {
    let id: String
    let name: String
    let provider: String
    let compatibleOctaveModels: [String]?
}

private struct HumeConfigRequest: Encodable {
    let name: String
    let eviVersion: String
    let prompt: HumeConfigPrompt
    let voice: HumeVoiceReference
    let versionDescription: String
}

private struct HumeConfigPrompt: Encodable {
    let text: String
}

private struct HumeVoiceReference: Encodable {
    let id: String
    let provider: String
}

private struct HumeConfigResponse: Decodable {
    let id: String?
    let version: Int?
}

private struct HumeWaveHeader {
    let sampleRate: UInt32
    let channelCount: UInt16
    let bitsPerSample: UInt16
    let headerSize: Int

    init?(data: Data) {
        guard data.count >= 44 else { return nil }
        let chunkID = String(decoding: data.prefix(4), as: UTF8.self)
        let format = String(decoding: data.dropFirst(8).prefix(4), as: UTF8.self)
        guard chunkID == "RIFF", format == "WAVE" else { return nil }
        sampleRate = data.subdata(in: 24..<28).withUnsafeBytes { $0.load(as: UInt32.self) }
        channelCount = data.subdata(in: 22..<24).withUnsafeBytes { $0.load(as: UInt16.self) }
        bitsPerSample = data.subdata(in: 34..<36).withUnsafeBytes { $0.load(as: UInt16.self) }
        headerSize = 44
    }
}
