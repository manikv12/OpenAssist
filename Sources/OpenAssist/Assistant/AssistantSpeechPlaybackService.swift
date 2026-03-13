import AppKit
@preconcurrency import AVFoundation
import Foundation
import Hume

enum AssistantSpeechEngine: String, CaseIterable, Codable, Identifiable, Sendable {
    case humeOctave
    case macos

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .humeOctave:
            return "Hume Octave"
        case .macos:
            return "macOS"
        }
    }
}

enum AssistantSpeechFallbackPolicy: String, Codable, Sendable {
    case macOS
    case disabled
}

enum AssistantSpeechHealthState: String, Codable, Sendable {
    case unknown
    case healthy
    case degraded
    case unavailable
}

struct AssistantSpeechHealth: Equatable, Sendable {
    var engine: AssistantSpeechEngine
    var state: AssistantSpeechHealthState
    var detail: String
    var checkedAt: Date
    var model: String?
    var usesFallback: Bool
    var installRecommended: Bool

    static let unknown = AssistantSpeechHealth(
        engine: .humeOctave,
        state: .unknown,
        detail: "Voice status has not been checked yet.",
        checkedAt: .distantPast,
        model: nil,
        usesFallback: false,
        installRecommended: false
    )

    var statusLabel: String {
        switch state {
        case .unknown:
            return "Unknown"
        case .healthy:
            return "Healthy"
        case .degraded:
            return "Needs Setup"
        case .unavailable:
            return "Unavailable"
        }
    }
}

struct AssistantSpeechRequest: Equatable, Sendable {
    let text: String
    let sessionID: String?
    let turnID: String?
    let timelineItemID: String?
    let preferredEngine: AssistantSpeechEngine
    let fallbackPolicy: AssistantSpeechFallbackPolicy
    let timeout: TimeInterval
    let voicePromptReference: String?
    let promptText: String?
}

struct AssistantSpeechVoiceOption: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let language: String

    var displayLabel: String {
        guard !language.isEmpty else { return name }
        return "\(name) (\(language))"
    }
}

enum AssistantSpeechError: LocalizedError {
    case emptyText
    case serviceUnavailable(String)
    case synthesisFailed(String)
    case invalidAudio
    case cancelled

    var errorDescription: String? {
        switch self {
        case .emptyText:
            return "Assistant voice skipped because there was no readable text."
        case .serviceUnavailable(let message):
            return message
        case .synthesisFailed(let message):
            return message
        case .invalidAudio:
            return "Hume returned audio that macOS could not play."
        case .cancelled:
            return "Assistant voice playback was cancelled."
        }
    }
}

@MainActor
protocol AssistantSpeechProvider: AnyObject {
    var engine: AssistantSpeechEngine { get }
    var hasActivePlayback: Bool { get }

    func speak(_ request: AssistantSpeechRequest) async throws
    func stopCurrentPlayback()
    func prewarmIfNeeded() async
    func healthStatus() async -> AssistantSpeechHealth
    func availableVoices() -> [AssistantSpeechVoiceOption]
}

struct AssistantSpeechTrigger {
    static func shouldAutoSpeak(
        incoming item: AssistantTimelineItem,
        existingItem: AssistantTimelineItem?,
        featureEnabled: Bool,
        lastSpokenTimelineItemID: String?
    ) -> Bool {
        guard featureEnabled else { return false }
        guard item.kind == .assistantFinal else { return false }
        guard item.source == .runtime else { return false }
        guard item.isStreaming == false else { return false }
        guard lastSpokenTimelineItemID != item.id else { return false }
        guard AssistantVisibleTextSanitizer.clean(item.text)?.assistantNonEmpty != nil else { return false }

        if let existingItem,
           existingItem.kind == .assistantFinal,
           existingItem.isStreaming == false,
           normalized(existingItem.text) == normalized(item.text) {
            return false
        }

        return true
    }

    private static func normalized(_ value: String?) -> String {
        (AssistantVisibleTextSanitizer.clean(value) ?? "")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
final class AssistantSpeechPlaybackService {
    var onPlaybackStateChange: ((Bool) -> Void)?

    private let settings: SettingsStore
    private let humeProvider: any AssistantSpeechProvider
    private let macOSProvider: any AssistantSpeechProvider

    init(
        settings: SettingsStore,
        humeProvider: (any AssistantSpeechProvider)? = nil,
        macOSProvider: (any AssistantSpeechProvider)? = nil
    ) {
        self.settings = settings
        let tokenService = HumeAccessTokenService(settings: settings)
        self.humeProvider = humeProvider ?? HumeAssistantSpeechProvider(
            settings: settings,
            tokenService: tokenService
        )
        self.macOSProvider = macOSProvider ?? MacOSAssistantSpeechProvider(settings: settings)
    }

    func speak(text: String, request: AssistantSpeechRequest) async throws {
        let normalizedText = AssistantVisibleTextSanitizer.clean(text)?.assistantNonEmpty
        guard let normalizedText else {
            throw AssistantSpeechError.emptyText
        }

        let normalizedRequest = AssistantSpeechRequest(
            text: normalizedText,
            sessionID: request.sessionID,
            turnID: request.turnID,
            timelineItemID: request.timelineItemID,
            preferredEngine: request.preferredEngine,
            fallbackPolicy: request.fallbackPolicy,
            timeout: request.timeout,
            voicePromptReference: request.voicePromptReference,
            promptText: request.promptText
        )

        if hasActivePlayback {
            if settings.assistantInterruptCurrentSpeechOnNewReply {
                stopCurrentPlayback()
            } else {
                return
            }
        }

        onPlaybackStateChange?(true)
        defer { onPlaybackStateChange?(false) }

        switch normalizedRequest.preferredEngine {
        case .macos:
            try await macOSProvider.speak(normalizedRequest)
        case .humeOctave:
            do {
                try await humeProvider.speak(normalizedRequest)
            } catch is CancellationError {
                throw AssistantSpeechError.cancelled
            } catch {
                guard normalizedRequest.fallbackPolicy == .macOS else {
                    throw error
                }
                try await macOSProvider.speak(normalizedRequest)
            }
        }
    }

    func stopCurrentPlayback() {
        humeProvider.stopCurrentPlayback()
        macOSProvider.stopCurrentPlayback()
        onPlaybackStateChange?(false)
    }

    func prewarmIfNeeded() async {
        let provider = settings.assistantVoiceEngine == .humeOctave ? humeProvider : macOSProvider
        await provider.prewarmIfNeeded()
    }

    func healthStatus() async -> AssistantSpeechHealth {
        switch settings.assistantVoiceEngine {
        case .humeOctave:
            return await humeProvider.healthStatus()
        case .macos:
            return await macOSProvider.healthStatus()
        }
    }

    func availableMacOSVoices() -> [AssistantSpeechVoiceOption] {
        macOSProvider.availableVoices()
    }

    var hasActivePlayback: Bool {
        humeProvider.hasActivePlayback || macOSProvider.hasActivePlayback
    }
}

@MainActor
final class MacOSAssistantSpeechProvider: NSObject, AssistantSpeechProvider {
    let engine: AssistantSpeechEngine = .macos

    private let settings: SettingsStore
    private let synthesizer = AVSpeechSynthesizer()
    private var playbackContinuation: CheckedContinuation<Void, Error>?

    init(settings: SettingsStore) {
        self.settings = settings
        super.init()
        synthesizer.delegate = self
    }

    var hasActivePlayback: Bool {
        synthesizer.isSpeaking || playbackContinuation != nil
    }

    func speak(_ request: AssistantSpeechRequest) async throws {
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw AssistantSpeechError.emptyText
        }

        stopCurrentPlayback()

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = Float(AssistantHumeDefaults.speechRate)

        if let voiceIdentifier = settings.assistantTTSFallbackVoiceIdentifier.nonEmpty,
           let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            utterance.voice = voice
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            playbackContinuation = continuation
            synthesizer.speak(utterance)
        }
    }

    func stopCurrentPlayback() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        if let continuation = playbackContinuation {
            playbackContinuation = nil
            continuation.resume(throwing: AssistantSpeechError.cancelled)
        }
    }

    func prewarmIfNeeded() async {}

    func healthStatus() async -> AssistantSpeechHealth {
        let voiceName: String
        if let voiceIdentifier = settings.assistantTTSFallbackVoiceIdentifier.nonEmpty,
           let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            voiceName = voice.name
        } else {
            voiceName = "System Default"
        }

        return AssistantSpeechHealth(
            engine: .macos,
            state: .healthy,
            detail: "macOS speech is ready with \(voiceName).",
            checkedAt: Date(),
            model: nil,
            usesFallback: false,
            installRecommended: false
        )
    }

    func availableVoices() -> [AssistantSpeechVoiceOption] {
        [
            AssistantSpeechVoiceOption(id: "", name: "System Default", language: "")
        ] + AVSpeechSynthesisVoice.speechVoices()
            .map {
                AssistantSpeechVoiceOption(
                    id: $0.identifier,
                    name: $0.name,
                    language: $0.language
                )
            }
            .sorted {
                $0.displayLabel.localizedCaseInsensitiveCompare($1.displayLabel) == .orderedAscending
            }
    }

    fileprivate func handleSpeechDidFinish() {
        guard let continuation = playbackContinuation else { return }
        playbackContinuation = nil
        continuation.resume()
    }

    fileprivate func handleSpeechDidCancel() {
        guard let continuation = playbackContinuation else { return }
        playbackContinuation = nil
        continuation.resume(throwing: AssistantSpeechError.cancelled)
    }
}

@MainActor
final class HumeAssistantSpeechProvider: NSObject, AssistantSpeechProvider {
    let engine: AssistantSpeechEngine = .humeOctave

    private let settings: SettingsStore
    private let tokenService: HumeAccessTokenService
    private lazy var client = HumeClient(options: .accessTokenProvider { [weak self] in
        guard let self else {
            throw AssistantSpeechError.serviceUnavailable("Hume access token provider is no longer available.")
        }
        return try await self.tokenService.currentAccessToken()
    })

    private var audioPlayer: AVAudioPlayer?
    private var activeGenerationID: UUID?
    private var playbackContinuation: CheckedContinuation<Void, Error>?
    private var lastPrewarmAt: Date?

    init(settings: SettingsStore, tokenService: HumeAccessTokenService) {
        self.settings = settings
        self.tokenService = tokenService
        super.init()
    }

    var hasActivePlayback: Bool {
        activeGenerationID != nil || audioPlayer?.isPlaying == true || playbackContinuation != nil
    }

    func speak(_ request: AssistantSpeechRequest) async throws {
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw AssistantSpeechError.emptyText
        }
        guard let voiceID = settings.assistantHumeVoiceID.assistantNonEmpty else {
            throw HumeAssistantVoiceError.missingVoiceSelection
        }

        stopCurrentPlayback()
        let generationID = UUID()
        activeGenerationID = generationID

        do {
            let audioData = try await synthesize(text: text, voiceID: voiceID, timeout: request.timeout)
            guard activeGenerationID == generationID else {
                throw AssistantSpeechError.cancelled
            }
            try await play(audioData: audioData, generationID: generationID)
        } catch {
            if activeGenerationID == generationID {
                activeGenerationID = nil
            }
            throw error
        }
    }

    func stopCurrentPlayback() {
        activeGenerationID = nil
        if audioPlayer?.isPlaying == true {
            audioPlayer?.stop()
        }
        audioPlayer = nil
        if let continuation = playbackContinuation {
            playbackContinuation = nil
            continuation.resume(throwing: AssistantSpeechError.cancelled)
        }
    }

    func prewarmIfNeeded() async {
        if let lastPrewarmAt,
           Date().timeIntervalSince(lastPrewarmAt) < 20 {
            return
        }
        _ = try? await tokenService.currentAccessToken()
        lastPrewarmAt = Date()
    }

    func healthStatus() async -> AssistantSpeechHealth {
        let usesFallback = settings.assistantTTSFallbackToMacOS
        guard settings.assistantHumeAPIKey.assistantNonEmpty != nil,
              settings.assistantHumeSecretKey.assistantNonEmpty != nil else {
            return AssistantSpeechHealth(
                engine: .humeOctave,
                state: .degraded,
                detail: "Add your Hume API key and Secret key to use Hume voice.",
                checkedAt: Date(),
                model: settings.assistantHumeVoiceName.assistantNonEmpty,
                usesFallback: usesFallback,
                installRecommended: false
            )
        }

        guard settings.assistantHumeVoiceID.assistantNonEmpty != nil else {
            return AssistantSpeechHealth(
                engine: .humeOctave,
                state: .degraded,
                detail: "Choose a Hume voice before using Hume Octave.",
                checkedAt: Date(),
                model: settings.assistantHumeVoiceName.assistantNonEmpty,
                usesFallback: usesFallback,
                installRecommended: false
            )
        }

        do {
            _ = try await tokenService.currentAccessToken()
            let voiceName = settings.assistantHumeVoiceName.assistantNonEmpty ?? "selected voice"
            return AssistantSpeechHealth(
                engine: .humeOctave,
                state: .healthy,
                detail: "Hume Octave is ready with \(voiceName).",
                checkedAt: Date(),
                model: voiceName,
                usesFallback: usesFallback,
                installRecommended: false
            )
        } catch {
            return AssistantSpeechHealth(
                engine: .humeOctave,
                state: .unavailable,
                detail: error.localizedDescription,
                checkedAt: Date(),
                model: settings.assistantHumeVoiceName.assistantNonEmpty,
                usesFallback: usesFallback,
                installRecommended: false
            )
        }
    }

    func availableVoices() -> [AssistantSpeechVoiceOption] {
        []
    }

    fileprivate func handleAudioDidFinish(successfully flag: Bool) {
        guard let continuation = playbackContinuation else { return }
        playbackContinuation = nil
        audioPlayer = nil
        activeGenerationID = nil
        if flag {
            continuation.resume()
        } else {
            continuation.resume(throwing: AssistantSpeechError.invalidAudio)
        }
    }

    fileprivate func handleAudioDecodeError(_ error: Error?) {
        guard let continuation = playbackContinuation else { return }
        playbackContinuation = nil
        audioPlayer = nil
        activeGenerationID = nil
        continuation.resume(throwing: error ?? AssistantSpeechError.invalidAudio)
    }

    private func synthesize(text: String, voiceID: String, timeout: TimeInterval) async throws -> Data {
        let request = PostedTts(
            context: nil,
            format: .wav(FormatWav()),
            numGenerations: 1,
            splitUtterances: nil,
            stripHeaders: nil,
            utterances: [
                PostedUtterance(
                    description: nil,
                    speed: nil,
                    trailingSilence: nil,
                    text: text,
                    voice: .postedUtteranceVoiceWithId(
                        PostedUtteranceVoiceWithId(
                            id: voiceID,
                            provider: settings.assistantHumeVoiceSource.ttsProvider
                        )
                    )
                )
            ],
            instantMode: nil,
            includeTimestampTypes: nil,
            version: nil
        )

        do {
            let data = try await client.tts.tts.synthesizeFile(
                request: request,
                timeoutDuration: max(5, timeout),
                maxRetries: 0
            )
            guard !data.isEmpty else {
                throw AssistantSpeechError.invalidAudio
            }
            return data
        } catch {
            throw AssistantSpeechError.synthesisFailed(error.localizedDescription)
        }
    }

    private func play(audioData: Data, generationID: UUID) async throws {
        let player = try AVAudioPlayer(data: audioData)
        player.delegate = self
        player.prepareToPlay()
        audioPlayer = player

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            playbackContinuation = continuation
            if player.play() == false {
                playbackContinuation = nil
                audioPlayer = nil
                activeGenerationID = nil
                continuation.resume(throwing: AssistantSpeechError.invalidAudio)
                return
            }
        }

        if activeGenerationID == generationID {
            activeGenerationID = nil
        }
    }
}

struct AssistantLegacyTADACleanupSupport {
    private let fileManager = FileManager.default

    func hasLegacyArtifacts() -> Bool {
        legacyArtifactURLs().contains { fileManager.fileExists(atPath: $0.path) }
    }

    func removeLegacyArtifacts() throws -> String {
        stopLegacyTADAProcess()

        var removedPaths: [String] = []
        for url in legacyArtifactURLs() where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
            removedPaths.append(url.path)
        }

        guard !removedPaths.isEmpty else {
            return "There was no old local TADA data to remove."
        }

        return "Removed old local TADA data from \(removedPaths.count) location(s)."
    }

    private func stopLegacyTADAProcess() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        process.arguments = ["-f", "AssistantVoice/TADAService/server.py"]
        try? process.run()
        process.waitUntilExit()
    }

    private func legacyArtifactURLs() -> [URL] {
        let home = fileManager.homeDirectoryForCurrentUser
        let appSupport = home
            .appendingPathComponent("Library/Application Support/OpenAssist/AssistantVoice/TADAService", isDirectory: true)
        let tempOutput = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("openassist-tada", isDirectory: true)
        let hubRoots = [
            home.appendingPathComponent(".cache/huggingface/hub", isDirectory: true),
            home.appendingPathComponent("Library/Caches/huggingface/hub", isDirectory: true)
        ]
        let modelIDs = [
            "HumeAI/tada-1b",
            "HumeAI/tada-codec",
            "meta-llama/Llama-3.2-1B"
        ]

        var urls = [appSupport, tempOutput]
        for hubRoot in hubRoots {
            let locksRoot = hubRoot.appendingPathComponent(".locks", isDirectory: true)
            for modelID in modelIDs {
                let name = "models--" + modelID.replacingOccurrences(of: "/", with: "--")
                urls.append(hubRoot.appendingPathComponent(name, isDirectory: true))
                urls.append(locksRoot.appendingPathComponent(name, isDirectory: true))
            }
        }

        var seen = Set<String>()
        return urls.filter { seen.insert($0.path).inserted }
    }
}

extension MacOSAssistantSpeechProvider: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.handleSpeechDidFinish()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.handleSpeechDidCancel()
        }
    }
}

extension HumeAssistantSpeechProvider: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.handleAudioDidFinish(successfully: flag)
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            self?.handleAudioDecodeError(error)
        }
    }
}
