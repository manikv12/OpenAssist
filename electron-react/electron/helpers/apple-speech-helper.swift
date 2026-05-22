import AVFoundation
import CoreAudio
import Foundation
import Speech

private let launchArguments = Array(CommandLine.arguments.dropFirst())
private let sessionDirectory = launchArguments.first { !$0.hasPrefix("-") }
private let shouldRecordAudioFile = launchArguments.contains("--record-audio")
private let shouldPreferExternalMicrophone = launchArguments.contains("--prefer-external-microphone")

private func argumentValue(after flag: String) -> String? {
    guard let index = launchArguments.firstIndex(of: flag) else { return nil }
    let valueIndex = launchArguments.index(after: index)
    guard valueIndex < launchArguments.endIndex else { return nil }
    let value = launchArguments[valueIndex].trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
}

private let selectedMicrophoneUID = argumentValue(after: "--microphone-uid")

private func emit(_ payload: [String: String]) {
    if let data = try? JSONSerialization.data(withJSONObject: payload),
       let line = String(data: data, encoding: .utf8) {
        print(line)
        fflush(stdout)
        if let sessionDirectory {
            try? FileManager.default.createDirectory(
                atPath: sessionDirectory,
                withIntermediateDirectories: true
            )
            let eventURL = URL(fileURLWithPath: sessionDirectory)
                .appendingPathComponent("\(payload["type"] ?? "event").json")
            try? data.write(to: eventURL, options: .atomic)
        }
    }
}

private struct MicrophoneOption: Encodable {
    let uid: String
    let name: String
    let isDefault: Bool
}

private enum MicrophoneManager {
    private static let discoveryDeviceTypes: [AVCaptureDevice.DeviceType] = [
        .builtInMicrophone,
        .externalUnknown
    ]

    static func availableMicrophones() -> [MicrophoneOption] {
        let defaultUID = AVCaptureDevice.default(for: .audio)?.uniqueID
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: discoveryDeviceTypes,
            mediaType: .audio,
            position: .unspecified
        )
        var devicesByUID: [String: MicrophoneOption] = [:]
        for device in session.devices {
            devicesByUID[device.uniqueID] = MicrophoneOption(
                uid: device.uniqueID,
                name: device.localizedName,
                isDefault: device.uniqueID == defaultUID
            )
        }
        return devicesByUID.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    static func preferredExternalMicrophoneUID() -> String? {
        let defaultUID = AVCaptureDevice.default(for: .audio)?.uniqueID
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: discoveryDeviceTypes,
            mediaType: .audio,
            position: .unspecified
        )
        let externalDevices = session.devices
            .filter { $0.deviceType != .builtInMicrophone }
            .sorted { lhs, rhs in
                lhs.localizedName.localizedCaseInsensitiveCompare(rhs.localizedName) == .orderedAscending
            }
        if let currentExternal = externalDevices.first(where: { $0.uniqueID == defaultUID }) {
            return currentExternal.uniqueID
        }
        return externalDevices.first?.uniqueID
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var defaultDeviceID: AudioDeviceID = kAudioObjectUnknown
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &defaultDeviceID
        )
        guard status == noErr, defaultDeviceID != kAudioObjectUnknown else { return nil }
        return defaultDeviceID
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        let uidRef = uid as CFString
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafePointer(to: uidRef) { uidPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                uidPointer,
                &dataSize,
                &deviceID
            )
        }
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    static func setDefaultInput(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var requested = deviceID
        let dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            dataSize,
            &requested
        )
        return status == noErr
    }
}

private func printMicrophonesAndExit() -> Never {
    do {
        let data = try JSONEncoder().encode(MicrophoneManager.availableMicrophones())
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write("\n".data(using: .utf8)!)
        exit(0)
    } catch {
        emit(["type": "error", "message": error.localizedDescription])
        exit(2)
    }
}

if launchArguments.contains("--list-microphones") {
    printMicrophonesAndExit()
}

private final class MicrophoneSelection {
    private let selectedUID: String?
    private let preferExternal: Bool
    private var previousDefaultInputDevice: AudioDeviceID?

    init(selectedUID: String?, preferExternal: Bool) {
        self.selectedUID = selectedUID
        self.preferExternal = preferExternal
    }

    func apply() {
        let requestedUID = selectedUID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetUID = requestedUID?.isEmpty == false
            ? requestedUID
            : (preferExternal ? MicrophoneManager.preferredExternalMicrophoneUID() : nil)
        guard let targetUID, !targetUID.isEmpty else { return }
        guard let selectedDeviceID = MicrophoneManager.deviceID(forUID: targetUID) else {
            emit(["type": "status", "message": "Selected microphone is not available."])
            return
        }
        guard let currentDefault = MicrophoneManager.defaultInputDeviceID() else {
            emit(["type": "status", "message": "Unable to read default microphone."])
            return
        }
        guard currentDefault != selectedDeviceID else { return }
        if MicrophoneManager.setDefaultInput(deviceID: selectedDeviceID) {
            previousDefaultInputDevice = currentDefault
            emit(["type": "status", "message": "Switched microphone."])
        } else {
            emit(["type": "status", "message": "Could not switch microphone."])
        }
    }

    func restore() {
        guard let previousDefaultInputDevice else { return }
        _ = MicrophoneManager.setDefaultInput(deviceID: previousDefaultInputDevice)
        self.previousDefaultInputDevice = nil
    }
}

private final class AudioFileCapture: NSObject {
    private var recorder: AVAudioRecorder?
    private var audioURL: URL?
    private var meterTimer: Timer?
    private var didFinish = false
    private let microphoneSelection = MicrophoneSelection(
        selectedUID: selectedMicrophoneUID,
        preferExternal: shouldPreferExternalMicrophone
    )

    func requestPermissions(_ completion: @escaping (Bool, String?) -> Void) {
        emit(["type": "status", "message": "Waiting for Microphone permission."])
        AVCaptureDevice.requestAccess(for: .audio) { microphoneAllowed in
            guard microphoneAllowed else {
                completion(false, "Microphone permission is not granted.")
                return
            }
            completion(true, nil)
        }
    }

    func start() {
        guard let sessionDirectory else {
            emit(["type": "error", "message": "Voice recording needs a session folder."])
            exit(2)
        }

        do {
            microphoneSelection.apply()
            let directoryURL = URL(fileURLWithPath: sessionDirectory, isDirectory: true)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let nextAudioURL = directoryURL.appendingPathComponent("voice-input.wav")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: 16_000.0,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            let nextRecorder = try AVAudioRecorder(url: nextAudioURL, settings: settings)
            nextRecorder.isMeteringEnabled = true
            nextRecorder.prepareToRecord()
            guard nextRecorder.record() else {
                microphoneSelection.restore()
                emit(["type": "error", "message": "Could not start microphone recording."])
                exit(2)
            }
            audioURL = nextAudioURL
            recorder = nextRecorder
            meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                self?.emitLevel()
            }
            emit(["type": "ready", "message": "recording"])
        } catch {
            microphoneSelection.restore()
            emit(["type": "error", "message": error.localizedDescription])
            exit(2)
        }
    }

    func stop() {
        guard !didFinish else { return }
        didFinish = true
        meterTimer?.invalidate()
        meterTimer = nil
        recorder?.stop()
        microphoneSelection.restore()
        guard let audioURL else {
            emit(["type": "error", "message": "No audio file was captured."])
            exit(2)
        }
        emit([
            "type": "final",
            "audioPath": audioURL.path,
            "fileName": audioURL.lastPathComponent,
            "mimeType": "audio/wav"
        ])
        exit(0)
    }

    private func emitLevel() {
        guard let recorder else { return }
        recorder.updateMeters()
        let power = recorder.averagePower(forChannel: 0)
        let level = min(1, max(0, (power + 54) / 42))
        emit(["type": "level", "level": String(format: "%.3f", level)])
    }
}

private final class AppleSpeechCapture: NSObject {
    private let audioEngine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var bestText = ""
    private var isStopping = false
    private var didFinish = false
    private var lastLevelEmit = Date.distantPast
    private let microphoneSelection = MicrophoneSelection(
        selectedUID: selectedMicrophoneUID,
        preferExternal: shouldPreferExternalMicrophone
    )

    func requestPermissions(_ completion: @escaping (Bool, String?) -> Void) {
        emit(["type": "status", "message": "Waiting for Speech Recognition permission."])
        SFSpeechRecognizer.requestAuthorization { speechStatus in
            guard speechStatus == .authorized else {
                completion(false, "Speech Recognition permission is not granted.")
                return
            }

            emit(["type": "status", "message": "Waiting for Microphone permission."])
            AVCaptureDevice.requestAccess(for: .audio) { microphoneAllowed in
                guard microphoneAllowed else {
                    completion(false, "Microphone permission is not granted.")
                    return
                }
                completion(true, nil)
            }
        }
    }

    func start() {
        guard let recognizer else {
            emit(["type": "error", "message": "Apple Speech is not available for this locale."])
            exit(2)
        }
        guard recognizer.isAvailable else {
            emit(["type": "error", "message": "Apple Speech is not available right now."])
            exit(2)
        }

        do {
            microphoneSelection.apply()
            let nextRequest = SFSpeechAudioBufferRecognitionRequest()
            nextRequest.shouldReportPartialResults = true
            if #available(macOS 13.0, *) {
                nextRequest.addsPunctuation = true
            }
            request = nextRequest

            let inputNode = audioEngine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)
            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
                guard let self, !self.isStopping else { return }
                self.request?.append(buffer)
                self.emitLevel(from: buffer)
            }

            audioEngine.prepare()
            try audioEngine.start()

            task = recognizer.recognitionTask(with: nextRequest) { [weak self] result, error in
                guard let self else { return }
                if let result {
                    self.bestText = result.bestTranscription.formattedString
                }
                if result?.isFinal == true {
                    self.finishAndExit()
                    return
                }
                if let error, !self.isStopping {
                    self.microphoneSelection.restore()
                    emit(["type": "error", "message": error.localizedDescription])
                    exit(2)
                }
            }

            emit(["type": "ready", "message": "listening"])
        } catch {
            microphoneSelection.restore()
            emit(["type": "error", "message": error.localizedDescription])
            exit(2)
        }
    }

    func stop() {
        guard !isStopping else { return }
        isStopping = true
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        request?.endAudio()

        // Match the native OpenAssist app's finalize delay (0.35s, see
        // AppleSpeechTranscriber.swift). isFinal still short-circuits this when
        // SFSpeech delivers a final result sooner; the timer is only a fallback.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.finishAndExit()
        }
    }

    private func finishAndExit() {
        guard !didFinish else { return }
        didFinish = true
        task?.cancel()
        microphoneSelection.restore()
        emit(["type": "final", "text": bestText])
        exit(0)
    }

    private func emitLevel(from buffer: AVAudioPCMBuffer) {
        let now = Date()
        guard now.timeIntervalSince(lastLevelEmit) >= 0.05 else { return }
        lastLevelEmit = now
        guard let channelData = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }

        let channelCount = max(1, Int(buffer.format.channelCount))
        var sum: Float = 0
        var sampleCount = 0
        for channel in 0..<min(channelCount, 2) {
            let samples = channelData[channel]
            for frame in stride(from: 0, to: frameLength, by: 8) {
                let sample = samples[frame]
                sum += sample * sample
                sampleCount += 1
            }
        }
        guard sampleCount > 0 else { return }

        let rms = sqrt(sum / Float(sampleCount))
        let decibels = 20 * log10(max(rms, 0.000001))
        let level = min(1, max(0, (decibels + 50) / 38))
        emit(["type": "level", "level": String(format: "%.3f", level)])
    }
}

if shouldRecordAudioFile {
    let capture = AudioFileCapture()
    capture.requestPermissions { allowed, message in
        guard allowed else {
            emit(["type": "error", "message": message ?? "Microphone permission was not granted."])
            exit(2)
        }

        DispatchQueue.main.async {
            capture.start()
        }
    }

    if let sessionDirectory {
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
            let stopPath = URL(fileURLWithPath: sessionDirectory).appendingPathComponent("stop").path
            if FileManager.default.fileExists(atPath: stopPath) {
                timer.invalidate()
                capture.stop()
            }
        }
    }

    RunLoop.main.run()
} else {
    let capture = AppleSpeechCapture()
    capture.requestPermissions { allowed, message in
        guard allowed else {
            emit(["type": "error", "message": message ?? "Voice permission was not granted."])
            exit(2)
        }

        DispatchQueue.main.async {
            capture.start()
        }
    }

    if sessionDirectory == nil {
        FileHandle.standardInput.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let command = String(data: data, encoding: .utf8),
               command.lowercased().contains("stop") {
                DispatchQueue.main.async {
                    capture.stop()
                }
            }
        }
    }

    if let sessionDirectory {
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
            let stopPath = URL(fileURLWithPath: sessionDirectory).appendingPathComponent("stop").path
            if FileManager.default.fileExists(atPath: stopPath) {
                timer.invalidate()
                capture.stop()
            }
        }
    }

    RunLoop.main.run()
}
