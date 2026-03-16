import AVFoundation
import Foundation

enum AudioEngineVoiceProcessing {
    @discardableResult
    static func enableIfAvailable(
        on audioEngine: AVAudioEngine,
        label: String
    ) -> Bool {
        if #available(macOS 10.15, *) {
            do {
                try audioEngine.inputNode.setVoiceProcessingEnabled(true)
                CrashReporter.logInfo("\(label) voice processing enabled on audio input")
                return true
            } catch {
                CrashReporter.logWarning("\(label) voice processing unavailable: \(error.localizedDescription)")
                return false
            }
        }

        CrashReporter.logInfo("\(label) voice processing unavailable on this macOS version")
        return false
    }
}
