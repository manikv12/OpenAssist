import AVFoundation
import CoreAudio
import Foundation

final class CloudTranscriber: NSObject {
    var onFinalText: ((String) -> Void)?
    var onStatusUpdate: ((String) -> Void)?
    var onHUDAlert: ((SpeechTranscriberHUDAlert) -> Void)?
    var onAudioLevel: ((Float) -> Void)?
    var onRecordingStateChange: ((Bool) -> Void)?

    private var audioEngine = AVAudioEngine()
    private let sampleQueue = DispatchQueue(label: "OpenAssist.CloudSamples")

    private var granted = false
    private(set) var isRecording = false
    private var isTranscribing = false
    private var pendingStopWorkItem: DispatchWorkItem?
    private var activeFinalizeTask: Task<Void, Never>?
    private var activeFinalizeRunID: String?
    private var previousDefaultInputDevice: AudioDeviceID?

    private var pcmSamples: [Float] = []
    private var autoDetectMicrophone = true
    private var selectedMicrophoneUID = ""

    private var provider: CloudTranscriptionProvider = .openAI
    private var model = CloudTranscriptionProvider.openAI.defaultModel
    private var baseURL = CloudTranscriptionProvider.openAI.defaultBaseURL
    private var apiKey = ""
    private var requestTimeoutSeconds: TimeInterval = 30
    private var finalizeDelaySeconds: TimeInterval = 0.35
    private var biasPhrases: [String] = []
    private var bypassManualMicSelectionUntilSettingsChange = false
    private var audioSetupRetryCooldownUntil: Date?

    private let targetSampleRate: Double = 16_000
    private let audioSetupRetryCooldownSeconds: TimeInterval = 1.5
    private let finalizeWatchdogGraceSeconds: TimeInterval = 5
    private let formatNotSupportedOSStatus = -10868

    private struct RequestConfiguration {
        let provider: CloudTranscriptionProvider
        let model: String
        let baseURL: String
        let apiKey: String
        let requestTimeoutSeconds: TimeInterval
        let biasPhrases: [String]
    }

    enum CloudTranscriberError: LocalizedError {
        case invalidBaseURL
        case emptyAudio
        case missingCredentials
        case unsupportedResponse
        case providerError(String)

        var errorDescription: String? {
            switch self {
            case .invalidBaseURL:
                return "Invalid provider base URL."
            case .emptyAudio:
                return "No speech captured."
            case .missingCredentials:
                return "Cloud API key is missing."
            case .unsupportedResponse:
                return "Provider returned an unsupported response."
            case .providerError(let message):
                return message
            }
        }
    }

    func requestPermissions(promptIfNeeded: Bool = true) {
        if Thread.isMainThread {
            requestMicrophonePermissionOnMain(promptIfNeeded: promptIfNeeded)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.requestMicrophonePermissionOnMain(promptIfNeeded: promptIfNeeded)
            }
        }
    }

    func applyMicrophoneSettings(autoDetect: Bool, microphoneUID: String) {
        if Thread.isMainThread {
            autoDetectMicrophone = autoDetect
            selectedMicrophoneUID = microphoneUID
            bypassManualMicSelectionUntilSettingsChange = false
            audioSetupRetryCooldownUntil = nil
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.autoDetectMicrophone = autoDetect
                self?.selectedMicrophoneUID = microphoneUID
                self?.bypassManualMicSelectionUntilSettingsChange = false
                self?.audioSetupRetryCooldownUntil = nil
            }
        }
    }

    func applyProviderSettings(
        provider: CloudTranscriptionProvider,
        model: String,
        baseURL: String,
        apiKey: String,
        requestTimeoutSeconds: TimeInterval
    ) {
        if Thread.isMainThread {
            self.provider = provider
            self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
            self.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            self.requestTimeoutSeconds = max(5, min(180, requestTimeoutSeconds))
            CrashReporter.logInfo(
                "Cloud transcription provider updated provider=\(provider.rawValue) model=\(self.model) baseURL=\(sanitizedURLString(self.baseURL) ?? "invalid") apiKeyPresent=\(!self.apiKey.isEmpty) timeout=\(Int(self.requestTimeoutSeconds.rounded()))s"
            )
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.provider = provider
                self?.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
                self?.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                self?.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                self?.requestTimeoutSeconds = max(5, min(180, requestTimeoutSeconds))
                if let self {
                    CrashReporter.logInfo(
                        "Cloud transcription provider updated provider=\(provider.rawValue) model=\(self.model) baseURL=\(self.sanitizedURLString(self.baseURL) ?? "invalid") apiKeyPresent=\(!self.apiKey.isEmpty) timeout=\(Int(self.requestTimeoutSeconds.rounded()))s"
                    )
                }
            }
        }
    }

    func applyFinalizeDelaySeconds(_ delaySeconds: TimeInterval) {
        if Thread.isMainThread {
            finalizeDelaySeconds = RecognitionTuning.clampedFinalizeDelay(delaySeconds)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.finalizeDelaySeconds = RecognitionTuning.clampedFinalizeDelay(delaySeconds)
            }
        }
    }

    func applyBiasPhrases(_ phrases: [String]) {
        if Thread.isMainThread {
            biasPhrases = phrases
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.biasPhrases = phrases
            }
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
        if Thread.isMainThread {
            stopRecordingOnMain(emitFinalText: emitFinalText)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.stopRecordingOnMain(emitFinalText: emitFinalText)
            }
        }
    }

    func trimMemoryUsage(aggressive: Bool) {
        if Thread.isMainThread {
            trimMemoryUsageOnMain(aggressive: aggressive)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.trimMemoryUsageOnMain(aggressive: aggressive)
            }
        }
    }

    private func requestMicrophonePermissionOnMain(promptIfNeeded: Bool) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            granted = true
            updateStatus("Permissions ready")

        case .notDetermined:
            guard promptIfNeeded else {
                granted = false
                return
            }

            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        self.granted = true
                        self.updateStatus("Permissions ready")
                    } else {
                        self.granted = false
                        self.updateStatus("Microphone permission not granted")
                    }
                }
            }

        default:
            granted = false
            updateStatus("Microphone permission not granted")
        }
    }

    @discardableResult
    private func startRecordingOnMain() -> Bool {
        guard granted else {
            requestMicrophonePermissionOnMain(promptIfNeeded: true)
            updateStatus("Permissions missing")
            CrashReporter.logWarning("Cloud start blocked: microphone permissions missing")
            return false
        }

        guard !isRecording, !isTranscribing else {
            if isTranscribing {
                updateStatus("Cloud transcription is still finalizing. Wait for Ready, then try again.")
                CrashReporter.logWarning("Cloud start blocked: transcription finalization still running")
            } else {
                CrashReporter.logInfo("Cloud start ignored: recording already active")
            }
            return false
        }

        if let cooldownUntil = audioSetupRetryCooldownUntil, cooldownUntil > Date() {
            let remaining = max(0.1, cooldownUntil.timeIntervalSinceNow)
            let remainingText = String(format: "%.1f", remaining)
            updateStatus("Audio device recovering. Retry in \(remainingText)s.")
            CrashReporter.logWarning("Cloud start blocked: audio setup cooldown active remaining=\(remainingText)s")
            return false
        }

        applyMicSelection()

        pendingStopWorkItem?.cancel()
        pendingStopWorkItem = nil
        sampleQueue.sync {
            pcmSamples.removeAll(keepingCapacity: false)
        }

        isRecording = true
        onRecordingStateChange?(true)

        let inputNode = rebuildAudioEngine()
        let hardwareFormat = inputNode.inputFormat(forBus: 0)
        CrashReporter.logInfo(
            "Cloud audio input prepared hardwareFormat=\(hardwareFormat) autoMic=\(autoDetectMicrophone)"
        )
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            restoreMicSelection()
            isRecording = false
            onRecordingStateChange?(false)
            updateStatus("Audio format setup failed")
            CrashReporter.logError("Cloud target audio format setup failed")
            return false
        }

        var converter: AVAudioConverter?
        var converterInputSignature: String?
        var converterFailureHandled = false

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let self else { return }

            let level = self.normalizedAudioLevel(from: buffer)
            DispatchQueue.main.async {
                self.onAudioLevel?(level)
            }

            let inputSignature = "\(buffer.format.sampleRate)-\(buffer.format.channelCount)-\(buffer.format.commonFormat.rawValue)-\(buffer.format.isInterleaved)"
            if converter == nil || converterInputSignature != inputSignature {
                converter = AVAudioConverter(from: buffer.format, to: targetFormat)
                converterInputSignature = inputSignature

                if converter == nil {
                    if !converterFailureHandled {
                        converterFailureHandled = true
                        DispatchQueue.main.async {
                            self.updateStatus("Audio converter setup failed")
                            CrashReporter.logError("Cloud audio converter setup failed at runtime from format=\(buffer.format)")
                            self.stopRecordingOnMain(emitFinalText: false)
                        }
                    }
                    return
                }

                self.sampleQueue.async {
                    self.pcmSamples.removeAll(keepingCapacity: false)
                }
            }

            guard let activeConverter = converter,
                  let convertedBuffer = self.convert(
                    buffer: buffer,
                    converter: activeConverter,
                    outputFormat: targetFormat
                  )
            else {
                return
            }

            let frameCount = Int(convertedBuffer.frameLength)
            guard frameCount > 0, let channelData = convertedBuffer.floatChannelData?.pointee else {
                return
            }

            let copied = Array(UnsafeBufferPointer(start: channelData, count: frameCount))
            self.sampleQueue.async {
                self.pcmSamples.append(contentsOf: copied)
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            updateStatus("Listening…")
            CrashReporter.logInfo(
                "Cloud recording started provider=\(provider.rawValue) model=\(model) autoMic=\(autoDetectMicrophone)"
            )
            return true
        } catch {
            inputNode.removeTap(onBus: 0)
            audioEngine.stop()
            audioEngine.reset()
            onAudioLevel?(0)
            restoreMicSelection()
            isRecording = false
            onRecordingStateChange?(false)
            let nsError = error as NSError
            let message = recoverFromAudioSetupFailure(error: nsError)
            updateStatus(message)
            CrashReporter.logError(
                "Cloud audio setup failed: \(error.localizedDescription) domain=\(nsError.domain) code=\(nsError.code) provider=\(provider.rawValue) model=\(model) autoMic=\(autoDetectMicrophone) bypassManualMic=\(bypassManualMicSelectionUntilSettingsChange)"
            )
            return false
        }
    }

    private func stopRecordingOnMain(emitFinalText: Bool) {
        if pendingStopWorkItem != nil {
            updateStatus("Finalizing already requested")
            return
        }

        guard isRecording || isTranscribing else {
            onAudioLevel?(0)
            onRecordingStateChange?(false)
            return
        }

        if isTranscribing && !isRecording {
            updateStatus("Finalizing in progress")
            return
        }

        if isRecording {
            let delay = finalizeDelaySeconds
            if delay > 0 {
                updateStatus("Finalizing…")
                let workItem = DispatchWorkItem { [weak self] in
                    self?.completeStopRecording(emitFinalText: emitFinalText)
                }
                pendingStopWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
                return
            }
        }

        completeStopRecording(emitFinalText: emitFinalText)
    }

    private func rebuildAudioEngine() -> AVAudioInputNode {
        let previousEngine = audioEngine
        previousEngine.stop()
        previousEngine.reset()
        previousEngine.inputNode.removeTap(onBus: 0)

        audioEngine = AVAudioEngine()
        return audioEngine.inputNode
    }

    private func completeStopRecording(emitFinalText: Bool) {
        pendingStopWorkItem = nil

        if isRecording {
            isRecording = false
            onRecordingStateChange?(false)

            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
            audioEngine.reset()
            onAudioLevel?(0)
        }

        restoreMicSelection()

        var samplesToTranscribe: [Float] = []
        sampleQueue.sync {
            samplesToTranscribe = pcmSamples
            pcmSamples.removeAll(keepingCapacity: false)
        }

        guard !samplesToTranscribe.isEmpty else {
            isTranscribing = false
            updateStatus("Ready")
            CrashReporter.logInfo("Cloud finalize skipped: no audio samples captured")
            return
        }

        let providerModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let providerBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let providerAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !providerModel.isEmpty, !providerBaseURL.isEmpty else {
            updateStatus("Cloud provider setup is incomplete. Open Settings > Recognition.")
            CrashReporter.logWarning("Cloud finalize blocked: provider setup incomplete provider=\(provider.rawValue)")
            return
        }
        guard !providerAPIKey.isEmpty else {
            updateStatus("Cloud API key missing. Open Settings > Recognition.")
            CrashReporter.logWarning("Cloud finalize blocked: provider API key missing provider=\(provider.rawValue)")
            return
        }

        isTranscribing = true
        updateStatus("Finalizing…")
        let runID = UUID().uuidString
        CrashReporter.logInfo(
            "Cloud finalize started run=\(runID) provider=\(provider.rawValue) model=\(providerModel) sampleCount=\(samplesToTranscribe.count)"
        )

        let requestConfiguration = RequestConfiguration(
            provider: provider,
            model: providerModel,
            baseURL: providerBaseURL,
            apiKey: providerAPIKey,
            requestTimeoutSeconds: requestTimeoutSeconds,
            biasPhrases: biasPhrases
        )
        let wavData = makeWAVData(from: samplesToTranscribe, sampleRate: Int(targetSampleRate))
        activeFinalizeRunID = runID

        let watchdogTimeoutSeconds = max(requestConfiguration.requestTimeoutSeconds + finalizeWatchdogGraceSeconds, 15)
        let stuckRunWatchdog = DispatchWorkItem { [weak self] in
            guard let self, self.isTranscribing, self.activeFinalizeRunID == runID else { return }

            self.activeFinalizeTask?.cancel()
            self.activeFinalizeTask = nil
            self.activeFinalizeRunID = nil
            self.isTranscribing = false
            self.updateStatus("Cloud transcription failed: The request timed out.")
            CrashReporter.logError(
                "Cloud finalize watchdog timed out run=\(runID) provider=\(requestConfiguration.provider.rawValue) model=\(requestConfiguration.model) timeout=\(Int(watchdogTimeoutSeconds.rounded()))s"
            )
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + watchdogTimeoutSeconds, execute: stuckRunWatchdog)

        activeFinalizeTask?.cancel()
        activeFinalizeTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }

            let result: Result<String, Error>
            do {
                let transcript = try await self.performTranscription(audioWAVData: wavData, config: requestConfiguration)
                result = .success(transcript)
            } catch {
                result = .failure(error)
            }

            await MainActor.run {
                stuckRunWatchdog.cancel()

                guard self.activeFinalizeRunID == runID else {
                    CrashReporter.logWarning(
                        "Cloud finalize completion ignored (stale run) run=\(runID) provider=\(requestConfiguration.provider.rawValue) model=\(requestConfiguration.model)"
                    )
                    return
                }

                self.activeFinalizeTask = nil
                self.activeFinalizeRunID = nil
                self.finishTranscription(runID: runID, emitFinalText: emitFinalText, result: result)
            }
        }
    }

    private func finishTranscription(runID: String, emitFinalText: Bool, result: Result<String, Error>) {
        isTranscribing = false

        switch result {
        case .success(let transcript):
            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            updateStatus("Ready")
            CrashReporter.logInfo(
                "Cloud finalize completed run=\(runID) provider=\(provider.rawValue) model=\(model) outputChars=\(trimmed.count)"
            )
            if emitFinalText, !trimmed.isEmpty {
                onFinalText?(trimmed)
            }

        case .failure(let error):
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            updateStatus("Cloud transcription failed: \(message)")
            CrashReporter.logError(
                "Cloud finalize failed run=\(runID) provider=\(provider.rawValue) model=\(model) reason=\(message)"
            )
        }
    }

    private func trimMemoryUsageOnMain(aggressive: Bool) {
        guard !isRecording, !isTranscribing else { return }

        pendingStopWorkItem?.cancel()
        pendingStopWorkItem = nil

        sampleQueue.sync {
            pcmSamples.removeAll(keepingCapacity: false)
        }

        if aggressive {
            audioEngine.stop()
            audioEngine.reset()
            onAudioLevel?(0)
        }
    }

    private func performTranscription(audioWAVData: Data, config: RequestConfiguration) async throws -> String {
        guard !audioWAVData.isEmpty else {
            throw CloudTranscriberError.emptyAudio
        }

        switch config.provider {
        case .openAI, .groq:
            return try await transcribeWithOpenAICompatibleAPI(audioWAVData: audioWAVData, config: config)
        case .deepgram:
            return try await transcribeWithDeepgram(audioWAVData: audioWAVData, config: config)
        case .gemini:
            return try await transcribeWithGemini(audioWAVData: audioWAVData, config: config)
        }
    }

    private func transcribeWithOpenAICompatibleAPI(audioWAVData: Data, config: RequestConfiguration) async throws -> String {
        if audioWAVData.count > 24_000_000 {
            throw CloudTranscriberError.providerError("Captured audio is too large for this provider upload limit.")
        }

        guard let endpoint = urlByAppendingPath(baseURL: config.baseURL, path: "audio/transcriptions") else {
            throw CloudTranscriberError.invalidBaseURL
        }
        let requestStart = Date()
        CrashReporter.logInfo(
            "Cloud request started provider=\(config.provider.rawValue) model=\(config.model) endpoint=\(sanitizedURLString(endpoint) ?? "invalid") audioBytes=\(audioWAVData.count) timeout=\(Int(config.requestTimeoutSeconds.rounded()))s"
        )

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = config.requestTimeoutSeconds
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let prompt = transcriptionPrompt(biasPhrases: config.biasPhrases)
        request.httpBody = makeMultipartFormData(
            boundary: boundary,
            fields: [
                ("model", config.model),
                ("prompt", prompt)
            ],
            fileFieldName: "file",
            fileName: "audio.wav",
            fileMimeType: "audio/wav",
            fileData: audioWAVData
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudTranscriberError.unsupportedResponse
        }
        logHTTPResponse(
            provider: config.provider,
            model: config.model,
            endpoint: endpoint,
            statusCode: httpResponse.statusCode,
            elapsedSince: requestStart,
            responseBytes: data.count
        )
        guard (200...299).contains(httpResponse.statusCode) else {
            let reason = extractErrorMessage(from: data) ?? "HTTP \(httpResponse.statusCode)"
            throw CloudTranscriberError.providerError(reason)
        }

        if let text = decodeOpenAIText(from: data), !text.isEmpty {
            return text
        }

        throw CloudTranscriberError.unsupportedResponse
    }

    private func transcribeWithDeepgram(audioWAVData: Data, config: RequestConfiguration) async throws -> String {
        guard var components = validatedBaseURLComponents(baseURL: config.baseURL) else {
            throw CloudTranscriberError.invalidBaseURL
        }

        var path = components.path
        while path.hasSuffix("/") && !path.isEmpty {
            path.removeLast()
        }
        if path.isEmpty {
            path = "/v1/listen"
        } else if !path.hasSuffix("/listen") {
            path += "/listen"
        }
        components.path = path

        var queryItems = components.queryItems ?? []
        if !queryItems.contains(where: { $0.name == "model" }) {
            queryItems.append(URLQueryItem(name: "model", value: config.model))
        }
        if !queryItems.contains(where: { $0.name == "smart_format" }) {
            queryItems.append(URLQueryItem(name: "smart_format", value: "true"))
        }
        components.queryItems = queryItems

        guard let endpoint = components.url else {
            throw CloudTranscriberError.invalidBaseURL
        }
        let requestStart = Date()
        CrashReporter.logInfo(
            "Cloud request started provider=\(config.provider.rawValue) model=\(config.model) endpoint=\(sanitizedURLString(endpoint) ?? "invalid") audioBytes=\(audioWAVData.count) timeout=\(Int(config.requestTimeoutSeconds.rounded()))s"
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = config.requestTimeoutSeconds
        request.setValue("Token \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.httpBody = audioWAVData

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudTranscriberError.unsupportedResponse
        }
        logHTTPResponse(
            provider: config.provider,
            model: config.model,
            endpoint: endpoint,
            statusCode: httpResponse.statusCode,
            elapsedSince: requestStart,
            responseBytes: data.count
        )
        guard (200...299).contains(httpResponse.statusCode) else {
            let reason = extractErrorMessage(from: data) ?? "HTTP \(httpResponse.statusCode)"
            throw CloudTranscriberError.providerError(reason)
        }

        if let text = decodeDeepgramText(from: data), !text.isEmpty {
            return text
        }

        throw CloudTranscriberError.unsupportedResponse
    }

    private func transcribeWithGemini(audioWAVData: Data, config: RequestConfiguration) async throws -> String {
        let encodedModel = config.model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? config.model
        guard let baseEndpoint = urlByAppendingPath(
            baseURL: config.baseURL,
            path: "models/\(encodedModel):generateContent"
        ) else {
            throw CloudTranscriberError.invalidBaseURL
        }

        guard var components = URLComponents(url: baseEndpoint, resolvingAgainstBaseURL: false) else {
            throw CloudTranscriberError.invalidBaseURL
        }
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "key", value: config.apiKey))
        components.queryItems = queryItems

        guard let endpoint = components.url else {
            throw CloudTranscriberError.invalidBaseURL
        }
        let requestStart = Date()
        CrashReporter.logInfo(
            "Cloud request started provider=\(config.provider.rawValue) model=\(config.model) endpoint=\(sanitizedURLString(endpoint) ?? "invalid") audioBytes=\(audioWAVData.count) timeout=\(Int(config.requestTimeoutSeconds.rounded()))s"
        )

        let payload: [String: Any] = [
            "contents": [
                [
                    "role": "user",
                    "parts": [
                        ["text": transcriptionPrompt(biasPhrases: config.biasPhrases)],
                        [
                            "inlineData": [
                                "mimeType": "audio/wav",
                                "data": audioWAVData.base64EncodedString()
                            ]
                        ]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0
            ]
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = config.requestTimeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudTranscriberError.unsupportedResponse
        }
        logHTTPResponse(
            provider: config.provider,
            model: config.model,
            endpoint: endpoint,
            statusCode: httpResponse.statusCode,
            elapsedSince: requestStart,
            responseBytes: data.count
        )
        guard (200...299).contains(httpResponse.statusCode) else {
            let reason = extractErrorMessage(from: data) ?? "HTTP \(httpResponse.statusCode)"
            throw CloudTranscriberError.providerError(reason)
        }

        if let text = decodeGeminiText(from: data), !text.isEmpty {
            return text
        }

        throw CloudTranscriberError.unsupportedResponse
    }

    private func transcriptionPrompt(biasPhrases: [String]) -> String {
        let compact = biasPhrases
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let limited = Array(compact.prefix(20))

        if limited.isEmpty {
            return "Transcribe this audio verbatim. Preserve wording and punctuation when clear."
        }

        return "Transcribe this audio verbatim. Preserve wording and punctuation when clear. Prefer these terms if acoustically plausible: \(limited.joined(separator: ", "))."
    }

    private func makeMultipartFormData(
        boundary: String,
        fields: [(String, String)],
        fileFieldName: String,
        fileName: String,
        fileMimeType: String,
        fileData: Data
    ) -> Data {
        var body = Data()

        for (name, value) in fields where !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.append("\(value)\r\n")
        }

        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"\(fileFieldName)\"; filename=\"\(fileName)\"\r\n")
        body.append("Content-Type: \(fileMimeType)\r\n\r\n")
        body.append(fileData)
        body.append("\r\n")
        body.append("--\(boundary)--\r\n")

        return body
    }

    private func makeWAVData(from samples: [Float], sampleRate: Int) -> Data {
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate: UInt32 = UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign: UInt16 = channels * (bitsPerSample / 8)

        var pcmData = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let intSample = Int16(clamped * Float(Int16.max))
            var intSampleLE = intSample.littleEndian
            pcmData.append(Data(bytes: &intSampleLE, count: MemoryLayout<Int16>.size))
        }

        let dataChunkSize = UInt32(pcmData.count)
        let riffChunkSize = 36 + dataChunkSize

        var wav = Data()
        wav.append("RIFF")
        wav.appendUInt32LE(riffChunkSize)
        wav.append("WAVE")

        wav.append("fmt ")
        wav.appendUInt32LE(16)
        wav.appendUInt16LE(1)
        wav.appendUInt16LE(channels)
        wav.appendUInt32LE(UInt32(sampleRate))
        wav.appendUInt32LE(byteRate)
        wav.appendUInt16LE(blockAlign)
        wav.appendUInt16LE(bitsPerSample)

        wav.append("data")
        wav.appendUInt32LE(dataChunkSize)
        wav.append(pcmData)
        return wav
    }

    private func decodeOpenAIText(from data: Data) -> String? {
        struct Response: Decodable {
            let text: String?
        }

        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            return nil
        }
        return decoded.text?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func decodeDeepgramText(from data: Data) -> String? {
        struct Response: Decodable {
            struct Results: Decodable {
                struct Channel: Decodable {
                    struct Alternative: Decodable {
                        let transcript: String?
                    }

                    let alternatives: [Alternative]
                }

                let channels: [Channel]
            }

            let results: Results?
        }

        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            return nil
        }

        return decoded.results?.channels.first?.alternatives.first?.transcript?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func decodeGeminiText(from data: Data) -> String? {
        struct Response: Decodable {
            struct Candidate: Decodable {
                struct Content: Decodable {
                    struct Part: Decodable {
                        let text: String?
                    }

                    let parts: [Part]?
                }

                let content: Content?
            }

            let candidates: [Candidate]?
        }

        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            return nil
        }

        return decoded.candidates?
            .first?
            .content?
            .parts?
            .compactMap(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractErrorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let error = object["error"] as? [String: Any],
           let message = error["message"] as? String,
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return message
        }

        if let message = object["message"] as? String,
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return message
        }

        if let message = object["err_msg"] as? String,
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return message
        }

        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func convert(
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

        if conversionError != nil {
            return nil
        }

        return outputBuffer
    }

    private func urlByAppendingPath(baseURL: String, path: String) -> URL? {
        guard var components = validatedBaseURLComponents(baseURL: baseURL) else { return nil }

        let existingPath = components.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let appendedPath = path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let merged = [existingPath, appendedPath]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        components.path = "/\(merged)"

        return components.url
    }

    private func validatedBaseURLComponents(baseURL: String) -> URLComponents? {
        guard var components = URLComponents(string: baseURL),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            return nil
        }

        let allowsInsecureLocalhost = scheme == "http" && isLoopbackHost(host)
        guard scheme == "https" || allowsInsecureLocalhost else {
            return nil
        }

        components.fragment = nil
        return components
    }

    private func isLoopbackHost(_ host: String) -> Bool {
        switch host {
        case "localhost", "127.0.0.1", "::1", "[::1]":
            return true
        default:
            return false
        }
    }

    private func applyMicSelection() {
        guard !bypassManualMicSelectionUntilSettingsChange else {
            previousDefaultInputDevice = nil
            return
        }

        guard !autoDetectMicrophone else {
            previousDefaultInputDevice = nil
            return
        }

        guard !selectedMicrophoneUID.isEmpty else {
            previousDefaultInputDevice = nil
            return
        }

        guard let selectedDeviceID = MicrophoneManager.deviceID(forUID: selectedMicrophoneUID) else {
            updateStatus("Selected microphone no longer available")
            previousDefaultInputDevice = nil
            return
        }

        guard let currentDefault = MicrophoneManager.defaultInputDeviceID() else {
            updateStatus("Unable to read default microphone")
            previousDefaultInputDevice = nil
            return
        }

        if currentDefault == selectedDeviceID {
            previousDefaultInputDevice = nil
            return
        }

        let changed = MicrophoneManager.setDefaultInput(deviceID: selectedDeviceID)
        if changed {
            previousDefaultInputDevice = currentDefault
        } else {
            updateStatus("Could not switch microphone")
            previousDefaultInputDevice = nil
        }
    }

    private func restoreMicSelection() {
        guard let previous = previousDefaultInputDevice else { return }
        _ = MicrophoneManager.setDefaultInput(deviceID: previous)
        previousDefaultInputDevice = nil
    }

    private func recoverFromAudioSetupFailure(error: NSError) -> String {
        audioSetupRetryCooldownUntil = Date().addingTimeInterval(audioSetupRetryCooldownSeconds)

        let isFormatNotSupported =
            error.code == formatNotSupportedOSStatus ||
            error.localizedDescription.contains("error -10868")

        if isFormatNotSupported {
            let preferredRecoveryUID = MicrophoneManager.builtInMicrophoneUID()

            if let recoveredUID = MicrophoneManager.recoverDefaultInputDevice(preferredUID: preferredRecoveryUID) {
                let recoveredName = MicrophoneManager.availableMicrophones()
                    .first(where: { $0.uid == recoveredUID })?
                    .name ?? recoveredUID

                if !autoDetectMicrophone,
                   !selectedMicrophoneUID.isEmpty,
                   !bypassManualMicSelectionUntilSettingsChange {
                    bypassManualMicSelectionUntilSettingsChange = true
                    CrashReporter.logWarning(
                        "Cloud audio setup recovery enabled: bypassing manual microphone selection after format error code=\(error.code) recoveredUID=\(recoveredUID)"
                    )
                } else {
                    CrashReporter.logWarning(
                        "Cloud audio setup recovery switched default input after format error code=\(error.code) recoveredUID=\(recoveredUID)"
                    )
                }

                onHUDAlert?(.micFallbackToDefault)
                return "Microphone route recovered (\(recoveredName)). Try again."
            }

            if !autoDetectMicrophone,
               !selectedMicrophoneUID.isEmpty,
               !bypassManualMicSelectionUntilSettingsChange {
                bypassManualMicSelectionUntilSettingsChange = true
                CrashReporter.logWarning(
                    "Cloud audio setup recovery enabled: bypassing manual microphone selection after format error code=\(error.code)"
                )
                onHUDAlert?(.micFallbackToDefault)
                return "Selected microphone failed. Switched to default microphone; try again."
            }

            onHUDAlert?(.micUnavailable)
            return "Microphone unavailable (CoreAudio -10868). Check Sound Input settings and retry."
        }

        onHUDAlert?(.micUnavailable)
        return "Audio setup failed: \(error.localizedDescription)"
    }

    private func normalizedAudioLevel(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else {
            return 0
        }

        let channelSamples = channelData.pointee
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }

        var sum: Float = 0
        for index in 0..<frameCount {
            let sample = channelSamples[index]
            sum += sample * sample
        }

        let meanSquare = sum / Float(frameCount)
        let rms = sqrtf(max(meanSquare, 1e-12))
        let db = 20 * log10f(rms)
        let normalized = (db + 70) / 70
        return max(0, min(1, normalized))
    }

    private func updateStatus(_ message: String) {
        if Thread.isMainThread {
            onStatusUpdate?(message)
        } else {
            DispatchQueue.main.async {
                self.onStatusUpdate?(message)
            }
        }
    }

    private func logHTTPResponse(
        provider: CloudTranscriptionProvider,
        model: String,
        endpoint: URL,
        statusCode: Int,
        elapsedSince start: Date,
        responseBytes: Int
    ) {
        let elapsed = max(0, Date().timeIntervalSince(start))
        let elapsedText = String(format: "%.2f", elapsed)
        CrashReporter.logInfo(
            "Cloud request completed provider=\(provider.rawValue) model=\(model) endpoint=\(sanitizedURLString(endpoint) ?? "invalid") status=\(statusCode) duration=\(elapsedText)s responseBytes=\(responseBytes)"
        )
    }

    private func sanitizedURLString(_ rawURL: String) -> String? {
        guard let url = URL(string: rawURL) else { return nil }
        return sanitizedURLString(url)
    }

    private func sanitizedURLString(_ url: URL) -> String? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.string
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }

    mutating func appendUInt16LE(_ value: UInt16) {
        var littleEndian = value.littleEndian
        append(Data(bytes: &littleEndian, count: MemoryLayout<UInt16>.size))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        var littleEndian = value.littleEndian
        append(Data(bytes: &littleEndian, count: MemoryLayout<UInt32>.size))
    }
}
