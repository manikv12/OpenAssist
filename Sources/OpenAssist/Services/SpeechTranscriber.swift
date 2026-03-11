import Foundation

enum SpeechTranscriberHUDAlert {
    case whisperStalled
    case whisperFailed
    case micFallbackToDefault
    case micUnavailable
}

final class SpeechTranscriber: NSObject {
    var onFinalText: ((String) -> Void)?
    var onStatusUpdate: ((String) -> Void)?
    var onHUDAlert: ((SpeechTranscriberHUDAlert) -> Void)?
    var onAudioLevel: ((Float) -> Void)?
    var onRecordingStateChange: ((Bool) -> Void)?

    private let appleTranscriber = AppleSpeechTranscriber()
    private let whisperTranscriber = WhisperTranscriber()
    private let cloudTranscriber = CloudTranscriber()

    private var currentEngineType: TranscriptionEngineType = .appleSpeech
    private var isRecording = false

    private struct AppleRecognitionSettings {
        var enableContextualBias = true
        var keepTextAcrossPauses = true
        var recognitionMode: RecognitionMode = .localOnly
        var autoPunctuation = true
        var finalizeDelaySeconds: TimeInterval = 0.35
        var customContextPhrases = ""
        var adaptiveBiasPhrases: [String] = []
    }

    private struct WhisperSettings {
        var selectedModelID = ""
        var useCoreML = true
        var autoUnloadIdleContext = true
        var idleContextUnloadDelaySeconds: TimeInterval = 8 * 60
        var finalizeDelaySeconds: TimeInterval = 0.35
        var biasPhrases: [String] = []
    }

    private struct CloudSettings {
        var provider: CloudTranscriptionProvider = .openAI
        var model = CloudTranscriptionProvider.openAI.defaultModel
        var baseURL = CloudTranscriptionProvider.openAI.defaultBaseURL
        var apiKey = ""
        var requestTimeoutSeconds: TimeInterval = 30
        var finalizeDelaySeconds: TimeInterval = 0.35
        var biasPhrases: [String] = []
    }

    private var lastAppleRecognitionSettings = AppleRecognitionSettings()
    private var lastWhisperSettings = WhisperSettings()
    private var lastCloudSettings = CloudSettings()

    override init() {
        super.init()
        wireCallbacks()
    }

    func requestPermissions(promptIfNeeded: Bool = true) {
        performOnMain {
            switch self.currentEngineType {
            case .appleSpeech:
                self.appleTranscriber.requestPermissions(promptIfNeeded: promptIfNeeded)
            case .whisperCpp:
                self.whisperTranscriber.requestPermissions(promptIfNeeded: promptIfNeeded)
            case .cloudProviders:
                self.cloudTranscriber.requestPermissions(promptIfNeeded: promptIfNeeded)
            }
        }
    }

    func setTranscriptionEngine(_ engineType: TranscriptionEngineType) {
        performOnMain {
            guard self.currentEngineType != engineType else { return }

            if self.isRecording {
                self.activeTranscriber.stopRecording(emitFinalText: false)
                self.isRecording = false
            }

            self.currentEngineType = engineType
            self.applyCachedSettingsToActiveEngine()
            CrashReporter.logInfo("Speech transcriber engine switched to \(engineType.rawValue)")
        }
    }

    func applyMicrophoneSettings(autoDetect: Bool, microphoneUID: String) {
        performOnMain {
            self.appleTranscriber.applyMicrophoneSettings(autoDetect: autoDetect, microphoneUID: microphoneUID)
            self.whisperTranscriber.applyMicrophoneSettings(autoDetect: autoDetect, microphoneUID: microphoneUID)
            self.cloudTranscriber.applyMicrophoneSettings(autoDetect: autoDetect, microphoneUID: microphoneUID)
        }
    }

    func applyRecognitionSettings(
        enableContextualBias: Bool,
        keepTextAcrossPauses: Bool,
        recognitionMode: RecognitionMode,
        autoPunctuation: Bool,
        finalizeDelaySeconds: TimeInterval,
        customContextPhrases: String,
        adaptiveBiasPhrases: [String] = []
    ) {
        performOnMain {
            self.lastAppleRecognitionSettings.enableContextualBias = enableContextualBias
            self.lastAppleRecognitionSettings.keepTextAcrossPauses = keepTextAcrossPauses
            self.lastAppleRecognitionSettings.recognitionMode = recognitionMode
            self.lastAppleRecognitionSettings.autoPunctuation = autoPunctuation
            self.lastAppleRecognitionSettings.finalizeDelaySeconds = finalizeDelaySeconds
            self.lastAppleRecognitionSettings.customContextPhrases = customContextPhrases
            self.lastAppleRecognitionSettings.adaptiveBiasPhrases = adaptiveBiasPhrases

            self.lastWhisperSettings.finalizeDelaySeconds = finalizeDelaySeconds
            self.lastWhisperSettings.biasPhrases = RecognitionTuning.whisperBiasPhrases(
                customContextPhrases: customContextPhrases,
                adaptiveBiasPhrases: adaptiveBiasPhrases
            )
            self.lastCloudSettings.finalizeDelaySeconds = finalizeDelaySeconds
            self.lastCloudSettings.biasPhrases = RecognitionTuning.whisperBiasPhrases(
                customContextPhrases: customContextPhrases,
                adaptiveBiasPhrases: adaptiveBiasPhrases
            )

            self.appleTranscriber.applyRecognitionSettings(
                enableContextualBias: enableContextualBias,
                keepTextAcrossPauses: keepTextAcrossPauses,
                recognitionMode: recognitionMode,
                autoPunctuation: autoPunctuation,
                finalizeDelaySeconds: finalizeDelaySeconds,
                customContextPhrases: customContextPhrases,
                adaptiveBiasPhrases: adaptiveBiasPhrases
            )
            self.whisperTranscriber.applyBiasPhrases(self.lastWhisperSettings.biasPhrases)
            self.whisperTranscriber.applyFinalizeDelaySeconds(finalizeDelaySeconds)
            self.cloudTranscriber.applyBiasPhrases(self.lastCloudSettings.biasPhrases)
            self.cloudTranscriber.applyFinalizeDelaySeconds(finalizeDelaySeconds)
        }
    }

    func applyWhisperSettings(selectedModelID: String, useCoreML: Bool) {
        performOnMain {
            self.lastWhisperSettings.selectedModelID = selectedModelID
            self.lastWhisperSettings.useCoreML = useCoreML
            self.whisperTranscriber.applyWhisperSettings(selectedModelID: selectedModelID, useCoreML: useCoreML)
        }
    }

    func applyWhisperContextRetentionSettings(autoUnloadIdleContext: Bool, idleContextUnloadDelaySeconds: TimeInterval) {
        performOnMain {
            self.lastWhisperSettings.autoUnloadIdleContext = autoUnloadIdleContext
            self.lastWhisperSettings.idleContextUnloadDelaySeconds = idleContextUnloadDelaySeconds
            self.whisperTranscriber.applyContextRetentionSettings(
                autoUnloadIdleContext: autoUnloadIdleContext,
                idleContextUnloadDelaySeconds: idleContextUnloadDelaySeconds
            )
        }
    }

    func applyCloudTranscriptionSettings(
        provider: CloudTranscriptionProvider,
        model: String,
        baseURL: String,
        apiKey: String,
        requestTimeoutSeconds: TimeInterval
    ) {
        performOnMain {
            self.lastCloudSettings.provider = provider
            self.lastCloudSettings.model = model
            self.lastCloudSettings.baseURL = baseURL
            self.lastCloudSettings.apiKey = apiKey
            self.lastCloudSettings.requestTimeoutSeconds = requestTimeoutSeconds
            self.cloudTranscriber.applyProviderSettings(
                provider: provider,
                model: model,
                baseURL: baseURL,
                apiKey: apiKey,
                requestTimeoutSeconds: requestTimeoutSeconds
            )
        }
    }

    @discardableResult
    func startRecording() -> Bool {
        if Thread.isMainThread {
            return startRecordingOnMain()
        }

        return DispatchQueue.main.sync {
            startRecordingOnMain()
        }
    }

    func stopRecording(emitFinalText: Bool = true) {
        performOnMain {
            self.activeTranscriber.stopRecording(emitFinalText: emitFinalText)
        }
    }

    func trimMemoryUsage(aggressive: Bool = false) {
        performOnMain {
            self.appleTranscriber.trimMemoryUsage(aggressive: aggressive)
            self.whisperTranscriber.trimMemoryUsage(aggressive: aggressive)
            self.cloudTranscriber.trimMemoryUsage(aggressive: aggressive)
        }
    }

    @discardableResult
    private func startRecordingOnMain() -> Bool {
        CrashReporter.logInfo("Speech transcriber start requested engine=\(currentEngineType.rawValue)")
        let started = activeTranscriber.startRecording()
        CrashReporter.logInfo("Speech transcriber start result engine=\(currentEngineType.rawValue) started=\(started)")
        if !started {
            isRecording = false
        }
        return started
    }

    private var activeTranscriber: EngineTranscriber {
        switch currentEngineType {
        case .appleSpeech:
            return .apple(appleTranscriber)
        case .whisperCpp:
            return .whisper(whisperTranscriber)
        case .cloudProviders:
            return .cloud(cloudTranscriber)
        }
    }

    private func applyCachedSettingsToActiveEngine() {
        switch currentEngineType {
        case .appleSpeech:
            appleTranscriber.applyRecognitionSettings(
                enableContextualBias: lastAppleRecognitionSettings.enableContextualBias,
                keepTextAcrossPauses: lastAppleRecognitionSettings.keepTextAcrossPauses,
                recognitionMode: lastAppleRecognitionSettings.recognitionMode,
                autoPunctuation: lastAppleRecognitionSettings.autoPunctuation,
                finalizeDelaySeconds: lastAppleRecognitionSettings.finalizeDelaySeconds,
                customContextPhrases: lastAppleRecognitionSettings.customContextPhrases,
                adaptiveBiasPhrases: lastAppleRecognitionSettings.adaptiveBiasPhrases
            )

        case .whisperCpp:
            whisperTranscriber.applyWhisperSettings(
                selectedModelID: lastWhisperSettings.selectedModelID,
                useCoreML: lastWhisperSettings.useCoreML
            )
            whisperTranscriber.applyContextRetentionSettings(
                autoUnloadIdleContext: lastWhisperSettings.autoUnloadIdleContext,
                idleContextUnloadDelaySeconds: lastWhisperSettings.idleContextUnloadDelaySeconds
            )
            whisperTranscriber.applyBiasPhrases(lastWhisperSettings.biasPhrases)
            whisperTranscriber.applyFinalizeDelaySeconds(lastWhisperSettings.finalizeDelaySeconds)
        case .cloudProviders:
            cloudTranscriber.applyProviderSettings(
                provider: lastCloudSettings.provider,
                model: lastCloudSettings.model,
                baseURL: lastCloudSettings.baseURL,
                apiKey: lastCloudSettings.apiKey,
                requestTimeoutSeconds: lastCloudSettings.requestTimeoutSeconds
            )
            cloudTranscriber.applyBiasPhrases(lastCloudSettings.biasPhrases)
            cloudTranscriber.applyFinalizeDelaySeconds(lastCloudSettings.finalizeDelaySeconds)
        }
    }

    private func wireCallbacks() {
        appleTranscriber.onFinalText = { [weak self] text in
            guard let self, self.currentEngineType == .appleSpeech else { return }
            self.onFinalText?(text)
        }

        appleTranscriber.onStatusUpdate = { [weak self] message in
            guard let self, self.currentEngineType == .appleSpeech else { return }
            self.onStatusUpdate?(message)
        }

        appleTranscriber.onAudioLevel = { [weak self] level in
            guard let self, self.currentEngineType == .appleSpeech else { return }
            self.onAudioLevel?(level)
        }

        appleTranscriber.onRecordingStateChange = { [weak self] recording in
            guard let self, self.currentEngineType == .appleSpeech else { return }
            self.isRecording = recording
            self.onRecordingStateChange?(recording)
        }

        whisperTranscriber.onFinalText = { [weak self] text in
            guard let self, self.currentEngineType == .whisperCpp else { return }
            self.onFinalText?(text)
        }

        whisperTranscriber.onStatusUpdate = { [weak self] message in
            guard let self, self.currentEngineType == .whisperCpp else { return }
            self.onStatusUpdate?(message)
        }

        whisperTranscriber.onHUDAlert = { [weak self] alert in
            guard let self, self.currentEngineType == .whisperCpp else { return }
            self.onHUDAlert?(alert)
        }

        whisperTranscriber.onAudioLevel = { [weak self] level in
            guard let self, self.currentEngineType == .whisperCpp else { return }
            self.onAudioLevel?(level)
        }

        whisperTranscriber.onRecordingStateChange = { [weak self] recording in
            guard let self, self.currentEngineType == .whisperCpp else { return }
            self.isRecording = recording
            self.onRecordingStateChange?(recording)
        }

        cloudTranscriber.onFinalText = { [weak self] text in
            guard let self, self.currentEngineType == .cloudProviders else { return }
            self.onFinalText?(text)
        }

        cloudTranscriber.onStatusUpdate = { [weak self] message in
            guard let self, self.currentEngineType == .cloudProviders else { return }
            self.onStatusUpdate?(message)
        }

        cloudTranscriber.onHUDAlert = { [weak self] alert in
            guard let self, self.currentEngineType == .cloudProviders else { return }
            self.onHUDAlert?(alert)
        }

        cloudTranscriber.onAudioLevel = { [weak self] level in
            guard let self, self.currentEngineType == .cloudProviders else { return }
            self.onAudioLevel?(level)
        }

        cloudTranscriber.onRecordingStateChange = { [weak self] recording in
            guard let self, self.currentEngineType == .cloudProviders else { return }
            self.isRecording = recording
            self.onRecordingStateChange?(recording)
        }
    }

    private func performOnMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    private enum EngineTranscriber {
        case apple(AppleSpeechTranscriber)
        case whisper(WhisperTranscriber)
        case cloud(CloudTranscriber)

        @discardableResult
        func startRecording() -> Bool {
            switch self {
            case let .apple(transcriber):
                return transcriber.startRecording()
            case let .whisper(transcriber):
                return transcriber.startRecording()
            case let .cloud(transcriber):
                return transcriber.startRecording()
            }
        }

        func stopRecording(emitFinalText: Bool) {
            switch self {
            case let .apple(transcriber):
                transcriber.stopRecording(emitFinalText: emitFinalText)
            case let .whisper(transcriber):
                transcriber.stopRecording(emitFinalText: emitFinalText)
            case let .cloud(transcriber):
                transcriber.stopRecording(emitFinalText: emitFinalText)
            }
        }
    }
}
