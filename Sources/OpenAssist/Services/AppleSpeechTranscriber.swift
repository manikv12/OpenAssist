import AVFoundation
import CoreAudio
import Foundation
import Speech

final class AppleSpeechTranscriber: NSObject {
    var onFinalText: ((String) -> Void)?
    var onStatusUpdate: ((String) -> Void)?
    var onAudioLevel: ((Float) -> Void)?
    var onRecordingStateChange: ((Bool) -> Void)?

    private var audioEngine = AVAudioEngine()
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionEngine: SFSpeechRecognizer?
    private var pendingFinalizeWorkItem: DispatchWorkItem?

    private var granted = false
    private(set) var isRecording: Bool = false
    private var isStopping: Bool = false
    private var committedTranscript = ""
    private var liveTranscript = ""
    private var bestTranscriptInCurrentSegment = ""
    private var previousDefaultInputDevice: AudioDeviceID?

    private var autoDetectMicrophone = true
    private var selectedMicrophoneUID = ""
    private var enableContextualBias = true
    private var keepTextAcrossPauses = true
    private var recognitionMode: RecognitionMode = .localOnly
    private var finalizeDelaySeconds: TimeInterval = 0.35
    private var customContextPhrases: [String] = []
    private var adaptiveBiasPhrases: [String] = []
    private var autoPunctuation = true

    override init() {
        let locale = Locale.current
        self.recognitionEngine = SFSpeechRecognizer(locale: locale)
        super.init()
    }

    func requestPermissions(promptIfNeeded: Bool = true) {
        if Thread.isMainThread {
            requestPermissionsOnMain(promptIfNeeded: promptIfNeeded)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.requestPermissionsOnMain(promptIfNeeded: promptIfNeeded)
            }
        }
    }

    func applyMicrophoneSettings(autoDetect: Bool, microphoneUID: String) {
        if Thread.isMainThread {
            applyMicrophoneSettingsOnMain(autoDetect: autoDetect, microphoneUID: microphoneUID)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.applyMicrophoneSettingsOnMain(autoDetect: autoDetect, microphoneUID: microphoneUID)
            }
        }
    }

    func applyRecognitionSettings(
        enableContextualBias: Bool,
        keepTextAcrossPauses: Bool,
        recognitionMode: RecognitionMode,
        autoPunctuation: Bool,
        finalizeDelaySeconds: TimeInterval,
        customContextPhrases: String,
        adaptiveBiasPhrases: [String]
    ) {
        if Thread.isMainThread {
            applyRecognitionSettingsOnMain(
                enableContextualBias: enableContextualBias,
                keepTextAcrossPauses: keepTextAcrossPauses,
                recognitionMode: recognitionMode,
                autoPunctuation: autoPunctuation,
                finalizeDelaySeconds: finalizeDelaySeconds,
                customContextPhrases: customContextPhrases,
                adaptiveBiasPhrases: adaptiveBiasPhrases
            )
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.applyRecognitionSettingsOnMain(
                    enableContextualBias: enableContextualBias,
                    keepTextAcrossPauses: keepTextAcrossPauses,
                    recognitionMode: recognitionMode,
                    autoPunctuation: autoPunctuation,
                    finalizeDelaySeconds: finalizeDelaySeconds,
                    customContextPhrases: customContextPhrases,
                    adaptiveBiasPhrases: adaptiveBiasPhrases
                )
            }
        }
    }

    private func requestPermissionsOnMain(promptIfNeeded: Bool) {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            requestAudioPermissionIfNeededOnMain(promptIfNeeded: promptIfNeeded)

        case .notDetermined:
            guard promptIfNeeded else {
                granted = false
                return
            }

            SFSpeechRecognizer.requestAuthorization { [weak self] status in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    switch status {
                    case .authorized:
                        self.requestAudioPermissionIfNeededOnMain(promptIfNeeded: promptIfNeeded)
                    default:
                        self.granted = false
                        self.update("Speech permission not granted")
                    }
                }
            }

        default:
            granted = false
            update("Speech permission not granted")
        }
    }

    private func applyMicrophoneSettingsOnMain(autoDetect: Bool, microphoneUID: String) {
        autoDetectMicrophone = autoDetect
        selectedMicrophoneUID = microphoneUID
    }

    private func applyRecognitionSettingsOnMain(
        enableContextualBias: Bool,
        keepTextAcrossPauses: Bool,
        recognitionMode: RecognitionMode,
        autoPunctuation: Bool,
        finalizeDelaySeconds: TimeInterval,
        customContextPhrases: String,
        adaptiveBiasPhrases: [String]
    ) {
        self.enableContextualBias = enableContextualBias
        self.keepTextAcrossPauses = keepTextAcrossPauses
        self.recognitionMode = recognitionMode
        self.autoPunctuation = autoPunctuation
        self.finalizeDelaySeconds = RecognitionTuning.clampedFinalizeDelay(finalizeDelaySeconds)
        self.customContextPhrases = RecognitionTuning.parseCustomPhrases(customContextPhrases)
        self.adaptiveBiasPhrases = adaptiveBiasPhrases
    }

    private func requestAudioPermissionIfNeededOnMain(promptIfNeeded: Bool) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            granted = true
            update("Permissions ready")

        case .notDetermined:
            guard promptIfNeeded else {
                granted = false
                return
            }

            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if granted {
                        self.granted = true
                        self.update("Permissions ready")
                    } else {
                        self.granted = false
                        self.update("Microphone permission not granted")
                    }
                }
            }

        default:
            granted = false
            update("Microphone permission not granted")
        }
    }

    private func update(_ message: String) {
        if Thread.isMainThread {
            onStatusUpdate?(message)
        } else {
            DispatchQueue.main.async {
                self.onStatusUpdate?(message)
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

    @discardableResult
    private func startRecordingOnMain() -> Bool {
        guard granted else {
            // Re-check/request permissions on demand so first-run users are not stuck.
            requestPermissionsOnMain(promptIfNeeded: true)
            update("Permissions missing")
            return false
        }

        guard !isRecording && !isStopping else { return false }
        guard let recognitionEngine else {
            update("No speech recognizer for locale")
            return false
        }
        guard recognitionEngine.isAvailable else {
            update("Speech recognizer unavailable")
            return false
        }

        applyMicSelection()

        pendingFinalizeWorkItem?.cancel()
        pendingFinalizeWorkItem = nil
        isStopping = false

        committedTranscript = ""
        liveTranscript = ""
        bestTranscriptInCurrentSegment = ""
        isRecording = true
        onRecordingStateChange?(true)

        guard startRecognitionTask() else {
            isRecording = false
            onRecordingStateChange?(false)
            return false
        }

        let inputNode = rebuildAudioEngine()

        // Rebuild the engine before installing a fresh tap so the input node picks up
        // the current hardware format after device or sample-rate changes.
        CrashReporter.logInfo(
            "Apple Speech audio input prepared hardwareFormat=\(inputNode.inputFormat(forBus: 0)) autoMic=\(autoDetectMicrophone)"
        )

        inputNode.removeTap(onBus: 0)
        // Use nil format so AVAudioEngine uses the node bus format directly.
        // This prevents NSException crashes from tap format mismatches.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            self.recognitionRequest?.append(buffer)

            let audioLevel = self.normalizedAudioLevel(from: buffer)
            DispatchQueue.main.async {
                self.onAudioLevel?(audioLevel)
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            update("Listening…")
            return true
        } catch {
            update("Audio setup failed: \(error.localizedDescription)")
            stopRecordingOnMain(emitFinalText: false)
            return false
        }
    }

    private func stopRecordingOnMain(emitFinalText: Bool = true) {
        guard isRecording || isStopping else {
            onAudioLevel?(0)
            onRecordingStateChange?(false)
            return
        }

        if isRecording {
            isRecording = false
            isStopping = true
            onRecordingStateChange?(false)

            recognitionRequest?.endAudio()

            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
            audioEngine.reset()
            onAudioLevel?(0)
        }

        pendingFinalizeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.finalizeStop(emitFinalText: emitFinalText)
        }
        pendingFinalizeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + finalizeDelaySeconds, execute: workItem)
    }

    private func rebuildAudioEngine() -> AVAudioInputNode {
        let previousEngine = audioEngine
        previousEngine.stop()
        previousEngine.reset()
        previousEngine.inputNode.removeTap(onBus: 0)

        audioEngine = AVAudioEngine()
        return audioEngine.inputNode
    }

    private func finalizeStop(emitFinalText: Bool) {
        pendingFinalizeWorkItem = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        restoreMicSelection()

        let text = mergedTranscript().trimmingCharacters(in: .whitespacesAndNewlines)
        committedTranscript = ""
        liveTranscript = ""
        bestTranscriptInCurrentSegment = ""
        isStopping = false

        update("Ready")

        if emitFinalText && !text.isEmpty {
            onFinalText?(text)
        }
    }

    private func trimMemoryUsageOnMain(aggressive: Bool) {
        guard !isRecording, !isStopping else { return }

        pendingFinalizeWorkItem?.cancel()
        pendingFinalizeWorkItem = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        committedTranscript = ""
        liveTranscript = ""
        bestTranscriptInCurrentSegment = ""

        if aggressive {
            audioEngine.stop()
            audioEngine.reset()
            onAudioLevel?(0)
        }
    }

    private func startRecognitionTask() -> Bool {
        guard let recognitionEngine else {
            update("No speech recognizer for locale")
            return false
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if #available(macOS 13, *) {
            switch recognitionMode {
            case .localOnly:
                request.requiresOnDeviceRecognition = true
            case .cloudOnly, .automatic:
                request.requiresOnDeviceRecognition = false
            }
            request.addsPunctuation = autoPunctuation
        }
        request.taskHint = .dictation
        if enableContextualBias {
            let defaults = [
                "Open Assist",
                "OpenClaw",
                "dictation",
                "transcription",
                "macOS"
            ]
            request.contextualStrings = RecognitionTuning.contextualHints(
                defaults: defaults,
                adaptive: adaptiveBiasPhrases,
                custom: customContextPhrases,
                limit: 80
            )
        }

        bestTranscriptInCurrentSegment = ""

        recognitionRequest = request
        recognitionTask = recognitionEngine.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async { [weak self] in
                self?.handleRecognitionCallback(result: result, error: error)
            }
        }

        return true
    }

    private func handleRecognitionCallback(result: SFSpeechRecognitionResult?, error: Error?) {
        guard isRecording || isStopping else { return }

        if let error {
            let nsError = error as NSError
            // Ignore expected cancellation noise when we stop/restart the task intentionally.
            if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 216 {
                return
            }
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                return
            }

            update("Error: \(error.localizedDescription)")
            stopRecordingOnMain(emitFinalText: false)
            return
        }

        guard let result else { return }
        let candidate = result.bestTranscription.formattedString
        liveTranscript = candidate

        if keepTextAcrossPauses {
            updateBestTranscriptForCurrentSegment(with: candidate)
        }

        if result.isFinal {
            if keepTextAcrossPauses {
                commitBestSegmentTranscript()
            } else {
                commitLiveTranscript()
            }

            if isRecording {
                _ = startRecognitionTask()
            }
        }
    }

    private func updateBestTranscriptForCurrentSegment(with candidate: String) {
        let candidateText = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingText = bestTranscriptInCurrentSegment.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !candidateText.isEmpty else { return }

        if RecognitionTuning.scoreTranscript(candidateText) >= RecognitionTuning.scoreTranscript(existingText) {
            bestTranscriptInCurrentSegment = candidateText
        }
    }

    private func commitBestSegmentTranscript() {
        let fallback = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let best = bestTranscriptInCurrentSegment.trimmingCharacters(in: .whitespacesAndNewlines)
        let chunk = RecognitionTuning.chooseBetterTranscript(primary: best, fallback: fallback)

        guard !chunk.isEmpty else {
            liveTranscript = ""
            bestTranscriptInCurrentSegment = ""
            return
        }

        if committedTranscript.isEmpty {
            committedTranscript = chunk
        } else {
            committedTranscript += " " + chunk
        }

        liveTranscript = ""
        bestTranscriptInCurrentSegment = ""
    }

    private func commitLiveTranscript() {
        let chunk = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !chunk.isEmpty else { return }

        if committedTranscript.isEmpty {
            committedTranscript = chunk
        } else {
            committedTranscript += " " + chunk
        }
        liveTranscript = ""
        bestTranscriptInCurrentSegment = ""
    }

    private func mergedTranscript() -> String {
        let current = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let best = bestTranscriptInCurrentSegment.trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = RecognitionTuning.chooseBetterTranscript(primary: best, fallback: current)

        if committedTranscript.isEmpty { return tail }
        if tail.isEmpty { return committedTranscript }
        return committedTranscript + " " + tail
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
            update("Selected microphone no longer available")
            previousDefaultInputDevice = nil
            return
        }

        guard let currentDefault = MicrophoneManager.defaultInputDeviceID() else {
            update("Unable to read default microphone")
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
            update("Could not switch microphone")
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
        for i in 0..<frameCount {
            let sample = channelSamples[i]
            sum += sample * sample
        }

        let meanSquare = sum / Float(frameCount)
        let rms = sqrtf(max(meanSquare, 1e-12))
        let db = 20 * log10f(rms)
        let normalized = (db + 70) / 70
        return max(0, min(1, normalized))
    }
}
