import AVFoundation
import CoreAudio
import Foundation

#if canImport(whisper)
import whisper

final class WhisperTranscriber: NSObject {
    var onFinalText: ((String) -> Void)?
    var onStatusUpdate: ((String) -> Void)?
    var onHUDAlert: ((SpeechTranscriberHUDAlert) -> Void)?
    var onAudioLevel: ((Float) -> Void)?
    var onAudioWaveformBins: (([Float]) -> Void)?
    var onRecordingStateChange: ((Bool) -> Void)?

    private var audioEngine = AVAudioEngine()
    private let sampleQueue = DispatchQueue(label: "OpenAssist.WhisperSamples")
    private var transcriptionQueue = DispatchQueue(label: "OpenAssist.WhisperTranscription")
    private var transcriptionQueueGeneration = 0
    private let finalizeWatchdogTimeoutSeconds: TimeInterval = 180
    private var autoUnloadIdleContext = true
    private var contextIdleReleaseDelaySeconds: TimeInterval = 8 * 60

    private var granted = false
    private(set) var isRecording = false
    private var isTranscribing = false
    private var previousDefaultInputDevice: AudioDeviceID?
    private var pcmSamples: [Float] = []

    private var autoDetectMicrophone = true
    private var selectedMicrophoneUID = ""

    private var selectedModelID = ""
    private var useCoreML = true
    private var finalizeDelaySeconds: TimeInterval = 0.35
    private var biasPhrases: [String] = []
    private var pendingStopWorkItem: DispatchWorkItem?
    private var pendingContextReleaseWorkItem: DispatchWorkItem?
    private var activeFinalizeRunID: String?
    private var cachedWhisperContext: OpaquePointer?
    private var cachedWhisperContextKey: WhisperContextCacheKey?

    private let modelManager = WhisperModelManager.shared
    private let whisperSampleRate: Float = 16_000
    private let minimumSpeechDurationSeconds: TimeInterval = 0.16
    private let minimumSpeechActiveFrameRatio: Float = 0.03
    private let minimumSpeechPeakAmplitude: Float = 0.003

    private struct SpeechGateAnalysis {
        let hasLikelySpeech: Bool
        let reason: String
    }

    private struct DecodedSegment {
        let text: String
        let noSpeechProbability: Float
    }

    private struct WhisperContextCacheKey: Equatable {
        let modelPath: String
        let useCoreML: Bool
        let queueGeneration: Int
    }

    override init() {
        super.init()
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
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.autoDetectMicrophone = autoDetect
                self?.selectedMicrophoneUID = microphoneUID
            }
        }
    }

    func applyWhisperSettings(selectedModelID: String, useCoreML: Bool) {
        if Thread.isMainThread {
            let settingsChanged = self.selectedModelID != selectedModelID || self.useCoreML != useCoreML
            self.selectedModelID = selectedModelID
            self.useCoreML = useCoreML
            if settingsChanged {
                releaseCachedWhisperContextAsync()
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let settingsChanged = self.selectedModelID != selectedModelID || self.useCoreML != useCoreML
                self.selectedModelID = selectedModelID
                self.useCoreML = useCoreML
                if settingsChanged {
                    self.releaseCachedWhisperContextAsync()
                }
            }
        }
    }

    func applyContextRetentionSettings(autoUnloadIdleContext: Bool, idleContextUnloadDelaySeconds: TimeInterval) {
        if Thread.isMainThread {
            setContextRetentionSettings(
                autoUnloadIdleContext: autoUnloadIdleContext,
                idleContextUnloadDelaySeconds: idleContextUnloadDelaySeconds
            )
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.setContextRetentionSettings(
                    autoUnloadIdleContext: autoUnloadIdleContext,
                    idleContextUnloadDelaySeconds: idleContextUnloadDelaySeconds
                )
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

    func applyFinalizeDelaySeconds(_ delaySeconds: TimeInterval) {
        if Thread.isMainThread {
            finalizeDelaySeconds = RecognitionTuning.clampedFinalizeDelay(delaySeconds)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.finalizeDelaySeconds = RecognitionTuning.clampedFinalizeDelay(delaySeconds)
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
        cancelScheduledContextRelease()

        guard granted else {
            requestMicrophonePermissionOnMain(promptIfNeeded: true)
            updateStatus("Permissions missing")
            CrashReporter.logWarning("Whisper start blocked: microphone permissions missing")
            return false
        }

        guard !isRecording, !isTranscribing else {
            if isRecording {
                updateStatus("Whisper is already recording")
                CrashReporter.logInfo("Whisper start ignored: recording already active")
            } else {
                updateStatus("Whisper is finalizing the previous segment. Wait for Ready, then try again.")
                CrashReporter.logWarning("Whisper start blocked: transcription finalization still running")
            }
            return false
        }

        guard modelManager.hasInstalledModel(id: selectedModelID) else {
            updateStatus("Whisper model not installed. Open Settings > Recognition to download one")
            CrashReporter.logWarning("Whisper start blocked: selected model is not installed (\(selectedModelID))")
            return false
        }

        applyMicSelection()

        pendingStopWorkItem?.cancel()
        pendingStopWorkItem = nil
        pcmSamples = []
        isRecording = true
        onRecordingStateChange?(true)

        let inputNode = rebuildAudioEngine()
        let hardwareFormat = inputNode.inputFormat(forBus: 0)
        CrashReporter.logInfo(
            "Whisper audio input prepared hardwareFormat=\(hardwareFormat) autoMic=\(autoDetectMicrophone)"
        )

        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)
        else {
            updateStatus("Whisper target audio format setup failed")
            CrashReporter.logError("Whisper target audio format setup failed")
            restoreMicSelection()
            isRecording = false
            onRecordingStateChange?(false)
            return false
        }

        // Build converter lazily from the first buffer's real format.
        // This avoids tap install crashes if the active hardware format changes.
        var converter: AVAudioConverter?
        var converterInputSignature: String?
        var converterFailureHandled = false

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let self else { return }

            let level = self.normalizedAudioLevel(from: buffer)
            let waveformBins = AudioWaveformShape.bins(from: buffer)
            DispatchQueue.main.async {
                self.onAudioLevel?(level)
                self.onAudioWaveformBins?(waveformBins)
            }

            let inputSignature = "\(buffer.format.sampleRate)-\(buffer.format.channelCount)-\(buffer.format.commonFormat.rawValue)-\(buffer.format.isInterleaved)"
            if converter == nil || converterInputSignature != inputSignature {
                converter = AVAudioConverter(from: buffer.format, to: targetFormat)
                converterInputSignature = inputSignature

                if converter == nil {
                    if !converterFailureHandled {
                        converterFailureHandled = true
                        DispatchQueue.global(qos: .background).async {
                            CrashReporter.logError("Whisper audio converter setup failed at runtime from format=\(buffer.format)")
                        }
                        DispatchQueue.main.async {
                            self.updateStatus("Audio converter setup failed")
                            self.stopRecordingOnMain(emitFinalText: false)
                        }
                    }
                    return
                }

                // Input format changed; clear any pre-converted accumulation to avoid mixing formats.
                self.sampleQueue.async {
                    self.pcmSamples = []
                }
            }

            guard let activeConverter = converter,
                  let convertedBuffer = self.convert(buffer: buffer, converter: activeConverter, outputFormat: targetFormat)
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
                "Whisper recording started model=\(selectedModelID) coreml=\(useCoreML) autoMic=\(autoDetectMicrophone)"
            )
            prewarmWhisperContextIfNeeded()
            return true
        } catch {
            inputNode.removeTap(onBus: 0)
            audioEngine.stop()
            onAudioLevel?(0)
            onAudioWaveformBins?(Array(repeating: 0, count: AudioWaveformShape.defaultBinCount))
            restoreMicSelection()
            isRecording = false
            onRecordingStateChange?(false)
            updateStatus("Audio setup failed: \(error.localizedDescription)")
            CrashReporter.logError("Whisper audio setup failed: \(error.localizedDescription)")
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
            onAudioWaveformBins?(Array(repeating: 0, count: AudioWaveformShape.defaultBinCount))
            onRecordingStateChange?(false)
            return
        }

        if isTranscribing && !isRecording {
            updateStatus("Finalizing in progress")
            return
        }

        if isRecording {
            suspendActiveRecording()
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

    private func suspendActiveRecording() {
        guard isRecording else { return }

        isRecording = false
        onRecordingStateChange?(false)

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        audioEngine.reset()
        onAudioLevel?(0)
        onAudioWaveformBins?(Array(repeating: 0, count: AudioWaveformShape.defaultBinCount))
    }

    private func completeStopRecording(emitFinalText: Bool) {
        pendingStopWorkItem = nil
        cancelScheduledContextRelease()

        guard let modelURL = modelManager.installedModelURL(for: selectedModelID) else {
            isRecording = false
            isTranscribing = false
            onRecordingStateChange?(false)
            onAudioLevel?(0)
            onAudioWaveformBins?(Array(repeating: 0, count: AudioWaveformShape.defaultBinCount))
            restoreMicSelection()
            updateStatus("Whisper model not installed. Open Settings > Recognition to download one")
            CrashReporter.logWarning("Whisper finalize blocked: selected model disappeared (\(selectedModelID))")
            return
        }

        let coreMLDirectoryURL = useCoreML ? modelManager.installedCoreMLDirectoryURL(for: selectedModelID) : nil
        let shouldForceCPUForStability = selectedModelID.hasPrefix("small") || selectedModelID.hasPrefix("medium")

        var samplesToTranscribe: [Float] = []
        sampleQueue.sync {
            samplesToTranscribe = pcmSamples
            pcmSamples.removeAll(keepingCapacity: false)
        }

        guard !samplesToTranscribe.isEmpty else {
            isTranscribing = false
            restoreMicSelection()
            updateStatus("Ready")
            CrashReporter.logInfo("Whisper finalize skipped: no audio samples captured")
            scheduleContextReleaseAfterIdle()
            return
        }

        let speechGate = analyzeSpeechLikelihood(in: samplesToTranscribe, sampleRate: whisperSampleRate)
        guard speechGate.hasLikelySpeech else {
            isTranscribing = false
            restoreMicSelection()
            updateStatus("Ready")
            CrashReporter.logInfo(
                "Whisper finalize skipped: speech gate rejected audio model=\(selectedModelID) reason=\(speechGate.reason) samples=\(samplesToTranscribe.count)"
            )
            scheduleContextReleaseAfterIdle()
            return
        }

        isTranscribing = true
        if shouldForceCPUForStability {
            updateStatus("Finalizing… (small/medium can take up to ~2 minutes on CPU)")
        } else {
            updateStatus("Finalizing…")
        }

        let threadCount = max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2))
        let shouldUseCoreML = coreMLDirectoryURL != nil && useCoreML && !shouldForceCPUForStability
        let prompt = RecognitionTuning.whisperInitialPrompt(from: biasPhrases)
        let runID = UUID().uuidString
        let selectedModelID = self.selectedModelID
        let sampleCount = samplesToTranscribe.count
        let startTime = Date()
        let queueGeneration = transcriptionQueueGeneration
        activeFinalizeRunID = runID

        if shouldForceCPUForStability, useCoreML {
            CrashReporter.logWarning("Whisper Core ML disabled for model=\(selectedModelID) due stability guard")
        }

        CrashReporter.logInfo(
            "Whisper finalize started run=\(runID) model=\(selectedModelID) samples=\(sampleCount) threads=\(threadCount) coreml=\(shouldUseCoreML)"
        )

        let stuckRunWatchdog = DispatchWorkItem { [weak self] in
            guard let self, self.isTranscribing, self.activeFinalizeRunID == runID else { return }
            CrashReporter.logWarning(
                "Whisper finalize still running after \(Int(self.finalizeWatchdogTimeoutSeconds))s run=\(runID) model=\(selectedModelID) samples=\(sampleCount)"
            )
            self.activeFinalizeRunID = nil
            self.isTranscribing = false
            self.restoreMicSelection()
            self.resetTranscriptionQueueAfterTimeout()
            self.updateStatus("Whisper finalize timed out and was reset. Try again.")
            self.onHUDAlert?(.whisperStalled)
            CrashReporter.logError("Whisper finalize timed out and transcription queue was reset run=\(runID) model=\(selectedModelID)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + finalizeWatchdogTimeoutSeconds, execute: stuckRunWatchdog)

        transcriptionQueue.async { [weak self] in
            guard let self else { return }

            let result = self.transcribe(
                samples: samplesToTranscribe,
                modelURL: modelURL,
                language: "en",
                threadCount: threadCount,
                useCoreML: shouldUseCoreML,
                prompt: prompt,
                queueGeneration: queueGeneration
            )

            DispatchQueue.main.async {
                stuckRunWatchdog.cancel()

                guard self.activeFinalizeRunID == runID else {
                    CrashReporter.logWarning(
                        "Whisper finalize completion ignored (stale run) run=\(runID) model=\(selectedModelID)"
                    )
                    return
                }

                self.activeFinalizeRunID = nil
                self.isTranscribing = false
                self.restoreMicSelection()

                let elapsedSeconds = Date().timeIntervalSince(startTime)
                let elapsedText = String(format: "%.2f", elapsedSeconds)

                switch result {
                case let .success(text):
                    if shouldUseCoreML {
                        self.updateStatus("Ready")
                    } else if self.useCoreML, coreMLDirectoryURL == nil {
                        self.updateStatus("Ready (Core ML encoder not installed for this model)")
                    } else {
                        self.updateStatus("Ready")
                    }

                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    CrashReporter.logInfo(
                        "Whisper finalize completed run=\(runID) model=\(selectedModelID) duration=\(elapsedText)s outputChars=\(trimmed.count)"
                    )
                    if emitFinalText, !trimmed.isEmpty {
                        self.onFinalText?(trimmed)
                    }

                case let .failure(error):
                    self.updateStatus("Whisper error: \(error.localizedDescription)")
                    self.onHUDAlert?(.whisperFailed)
                    CrashReporter.logError(
                        "Whisper finalize failed run=\(runID) model=\(selectedModelID) duration=\(elapsedText)s error=\(error.localizedDescription)"
                    )
                }

                self.scheduleContextReleaseAfterIdle()
            }
        }
    }

    private func transcribe(
        samples: [Float],
        modelURL: URL,
        language: String,
        threadCount: Int,
        useCoreML: Bool,
        prompt: String?,
        queueGeneration: Int
    ) -> Result<String, Error> {
        let contextKey = WhisperContextCacheKey(
            modelPath: modelURL.path,
            useCoreML: useCoreML,
            queueGeneration: queueGeneration
        )
        guard let ctx = resolvedWhisperContext(for: contextKey) else {
            return .failure(NSError(domain: "WhisperTranscriber", code: 2001, userInfo: [NSLocalizedDescriptionKey: "Failed to load whisper model"]))
        }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false
        params.no_context = true
        params.single_segment = false
        params.n_threads = Int32(max(1, threadCount))
        params.offset_ms = 0
        params.suppress_nst = true
        params.no_speech_thold = max(params.no_speech_thold, 0.65)

        let runResult: Int32 = language.withCString { languageCString in
            params.language = languageCString
            params.carry_initial_prompt = false

            let execute = {
                samples.withUnsafeBufferPointer { buffer in
                    whisper_full(ctx, params, buffer.baseAddress, Int32(samples.count))
                }
            }

            if let prompt, !prompt.isEmpty {
                return prompt.withCString { promptCString in
                    params.initial_prompt = promptCString
                    return execute()
                }
            } else {
                params.initial_prompt = nil
                return execute()
            }
        }

        guard runResult == 0 else {
            return .failure(NSError(domain: "WhisperTranscriber", code: 2002, userInfo: [NSLocalizedDescriptionKey: "whisper_full failed"]))
        }

        let segmentCount = whisper_full_n_segments(ctx)
        var segments: [DecodedSegment] = []
        segments.reserveCapacity(Int(segmentCount))

        for i in 0..<segmentCount {
            guard let raw = whisper_full_get_segment_text(ctx, i) else { continue }
            let text = String(cString: raw)
            let noSpeechProbability = whisper_full_get_segment_no_speech_prob(ctx, i)
            segments.append(
                DecodedSegment(
                    text: text,
                    noSpeechProbability: noSpeechProbability
                )
            )
        }

        let transcript = filteredTranscript(from: segments)
        return .success(transcript)
    }

    private func resolvedWhisperContext(for key: WhisperContextCacheKey) -> OpaquePointer? {
        if let cachedWhisperContext, cachedWhisperContextKey == key {
            return cachedWhisperContext
        }

        invalidateCachedWhisperContext(freeContext: true)

        var contextParams = whisper_context_default_params()
        contextParams.use_gpu = key.useCoreML
        // flash_attn has shown instability on some small/medium runs in production.
        contextParams.flash_attn = false

        guard let createdContext = whisper_init_from_file_with_params(key.modelPath, contextParams) else {
            return nil
        }

        cachedWhisperContext = createdContext
        cachedWhisperContextKey = key
        return createdContext
    }

    private func invalidateCachedWhisperContext(freeContext: Bool) {
        if freeContext, let cachedWhisperContext {
            whisper_free(cachedWhisperContext)
        }
        cachedWhisperContext = nil
        cachedWhisperContextKey = nil
    }

    private func releaseCachedWhisperContextAsync() {
        let queue = transcriptionQueue
        queue.async { [weak self] in
            self?.invalidateCachedWhisperContext(freeContext: true)
        }
    }

    private func prewarmWhisperContextIfNeeded() {
        guard let modelURL = modelManager.installedModelURL(for: selectedModelID) else {
            return
        }

        let shouldForceCPUForStability = selectedModelID.hasPrefix("small") || selectedModelID.hasPrefix("medium")
        let hasCoreMLEncoder = modelManager.installedCoreMLDirectoryURL(for: selectedModelID) != nil
        let shouldUseCoreML = useCoreML && hasCoreMLEncoder && !shouldForceCPUForStability
        let queueGeneration = transcriptionQueueGeneration
        let contextKey = WhisperContextCacheKey(
            modelPath: modelURL.path,
            useCoreML: shouldUseCoreML,
            queueGeneration: queueGeneration
        )

        let queue = transcriptionQueue
        queue.async { [weak self] in
            guard let self else { return }
            _ = self.resolvedWhisperContext(for: contextKey)
        }
    }

    private func cancelScheduledContextRelease() {
        pendingContextReleaseWorkItem?.cancel()
        pendingContextReleaseWorkItem = nil
    }

    private func scheduleContextReleaseAfterIdle() {
        guard autoUnloadIdleContext else {
            cancelScheduledContextRelease()
            return
        }

        cancelScheduledContextRelease()
        let delay = max(5, contextIdleReleaseDelaySeconds)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard !self.isRecording, !self.isTranscribing else { return }
            self.releaseCachedWhisperContextAsync()
            CrashReporter.logInfo("Whisper context released after idle window (\(Int(delay))s)")
        }
        pendingContextReleaseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func setContextRetentionSettings(autoUnloadIdleContext: Bool, idleContextUnloadDelaySeconds: TimeInterval) {
        self.autoUnloadIdleContext = autoUnloadIdleContext
        self.contextIdleReleaseDelaySeconds = max(5, idleContextUnloadDelaySeconds)

        if !autoUnloadIdleContext {
            cancelScheduledContextRelease()
            return
        }

        if !isRecording, !isTranscribing, cachedWhisperContext != nil {
            scheduleContextReleaseAfterIdle()
        }
    }

    private func trimMemoryUsageOnMain(aggressive: Bool) {
        guard !isRecording, !isTranscribing else { return }

        cancelScheduledContextRelease()
        releaseCachedWhisperContextAsync()

        sampleQueue.async { [weak self] in
            self?.pcmSamples.removeAll(keepingCapacity: false)
        }

        if aggressive {
            audioEngine.stop()
            audioEngine.reset()
            onAudioLevel?(0)
            onAudioWaveformBins?(Array(repeating: 0, count: AudioWaveformShape.defaultBinCount))
        }
    }

    private func resetTranscriptionQueueAfterTimeout() {
        transcriptionQueueGeneration += 1
        // The timed-out run may still be executing in the old queue. Drop references without
        // freeing so the new queue never reuses that context concurrently.
        invalidateCachedWhisperContext(freeContext: false)
        transcriptionQueue = DispatchQueue(label: "OpenAssist.WhisperTranscription")
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

    private func analyzeSpeechLikelihood(in samples: [Float], sampleRate: Float) -> SpeechGateAnalysis {
        guard !samples.isEmpty else {
            return SpeechGateAnalysis(hasLikelySpeech: false, reason: "empty-samples")
        }

        guard sampleRate > 0 else {
            return SpeechGateAnalysis(hasLikelySpeech: true, reason: "no-sample-rate")
        }

        let peakAmplitude = samples.reduce(Float(0)) { max($0, abs($1)) }
        guard peakAmplitude >= minimumSpeechPeakAmplitude else {
            return SpeechGateAnalysis(
                hasLikelySpeech: false,
                reason: String(format: "low-peak=%.4f", peakAmplitude)
            )
        }

        let frameLength = 320 // 20 ms @ 16 kHz
        let hopLength = 160 // 10 ms @ 16 kHz

        guard samples.count >= frameLength else {
            return SpeechGateAnalysis(
                hasLikelySpeech: false,
                reason: "too-short=\(samples.count)"
            )
        }

        var frameRMS: [Float] = []
        frameRMS.reserveCapacity(max(1, samples.count / hopLength))

        var frameStart = 0
        while frameStart + frameLength <= samples.count {
            var sumSquares: Float = 0
            for i in frameStart..<(frameStart + frameLength) {
                let sample = samples[i]
                sumSquares += sample * sample
            }
            let rms = sqrtf(max(sumSquares / Float(frameLength), 1e-12))
            frameRMS.append(rms)
            frameStart += hopLength
        }

        guard !frameRMS.isEmpty else {
            return SpeechGateAnalysis(hasLikelySpeech: false, reason: "no-frames")
        }

        let sortedRMS = frameRMS.sorted()
        let noiseFloorIndex = max(0, Int(Float(sortedRMS.count - 1) * 0.20))
        let noiseFloor = sortedRMS[noiseFloorIndex]
        let activeThreshold = max(noiseFloor * 2.2, 0.0025)
        let activeFrameCount = frameRMS.reduce(0) { partialResult, value in
            partialResult + (value >= activeThreshold ? 1 : 0)
        }

        let activeRatio = Float(activeFrameCount) / Float(frameRMS.count)
        let activeDurationSeconds = TimeInterval(activeFrameCount * hopLength) / TimeInterval(sampleRate)

        guard activeRatio >= minimumSpeechActiveFrameRatio else {
            return SpeechGateAnalysis(
                hasLikelySpeech: false,
                reason: String(format: "low-active-ratio=%.3f", activeRatio)
            )
        }

        guard activeDurationSeconds >= minimumSpeechDurationSeconds else {
            return SpeechGateAnalysis(
                hasLikelySpeech: false,
                reason: String(format: "short-active=%.3fs", activeDurationSeconds)
            )
        }

        return SpeechGateAnalysis(
            hasLikelySpeech: true,
            reason: String(
                format: "ok peak=%.4f active=%.3f dur=%.3fs",
                peakAmplitude,
                activeRatio,
                activeDurationSeconds
            )
        )
    }

    private func filteredTranscript(from segments: [DecodedSegment]) -> String {
        struct CandidateSegment {
            let text: String
            let noSpeechProbability: Float
            let wordCount: Int
        }

        let candidates = segments.compactMap { segment -> CandidateSegment? in
            let trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            return CandidateSegment(
                text: trimmed,
                noSpeechProbability: max(0, min(1, segment.noSpeechProbability)),
                wordCount: trimmed.split { $0.isWhitespace || $0.isNewline }.count
            )
        }

        guard !candidates.isEmpty else { return "" }

        let averageNoSpeechProbability =
            candidates.reduce(Float(0)) { $0 + $1.noSpeechProbability } / Float(candidates.count)
        let strongSpeechSegmentCount = candidates.reduce(0) { partialResult, candidate in
            partialResult + (candidate.noSpeechProbability < 0.55 ? 1 : 0)
        }
        let totalWordCount = candidates.reduce(0) { $0 + $1.wordCount }
        let totalCharacterCount = candidates.reduce(0) { $0 + $1.text.count }

        if strongSpeechSegmentCount == 0,
           averageNoSpeechProbability >= 0.78,
           (totalWordCount <= 8 || totalCharacterCount <= 48) {
            CrashReporter.logInfo(
                String(
                    format: "Whisper output dropped: no-speech gate avg=%.3f words=%d chars=%d",
                    averageNoSpeechProbability,
                    totalWordCount,
                    totalCharacterCount
                )
            )
            return ""
        }

        let keptSegments = candidates.filter { candidate in
            !(candidate.noSpeechProbability > 0.92 && candidate.wordCount <= 2 && candidate.text.count <= 12)
        }

        let transcript = keptSegments
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if transcript.isEmpty {
            CrashReporter.logInfo(
                String(
                    format: "Whisper output dropped: segment filter removed all content avg=%.3f segments=%d",
                    averageNoSpeechProbability,
                    candidates.count
                )
            )
        }

        return transcript
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

    private func applyMicSelection() {
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
}

#else

final class WhisperTranscriber: NSObject {
    var onFinalText: ((String) -> Void)?
    var onStatusUpdate: ((String) -> Void)?
    var onHUDAlert: ((SpeechTranscriberHUDAlert) -> Void)?
    var onAudioLevel: ((Float) -> Void)?
    var onAudioWaveformBins: (([Float]) -> Void)?
    var onRecordingStateChange: ((Bool) -> Void)?

    func requestPermissions(promptIfNeeded: Bool = true) {
        if promptIfNeeded {
            onStatusUpdate?("Whisper framework is unavailable")
        }
    }

    func applyMicrophoneSettings(autoDetect: Bool, microphoneUID: String) {}

    func applyWhisperSettings(selectedModelID: String, useCoreML: Bool) {}

    func applyContextRetentionSettings(autoUnloadIdleContext: Bool, idleContextUnloadDelaySeconds: TimeInterval) {}

    func applyBiasPhrases(_ phrases: [String]) {}

    func applyFinalizeDelaySeconds(_ delaySeconds: TimeInterval) {}

    func trimMemoryUsage(aggressive: Bool) {}

    @discardableResult
    func startRecording() -> Bool {
        onStatusUpdate?("Whisper framework is unavailable")
        return false
    }

    func stopRecording(emitFinalText: Bool = true) {
        onRecordingStateChange?(false)
        onAudioLevel?(0)
        onAudioWaveformBins?(Array(repeating: 0, count: AudioWaveformShape.defaultBinCount))
    }
}

#endif
