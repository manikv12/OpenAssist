import Foundation

enum TranscriberStatusPresentation: Equatable {
    case persistent(DictationUIStatus)
    case transientFailure(message: String)
}

enum TranscriberStatusInterpreter {
    static func interpret(_ message: String) -> TranscriberStatusPresentation {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if isTransientFailureMessage(trimmed) {
            return .transientFailure(message: trimmed)
        }
        return .persistent(DictationUIStatus.fromTranscriberMessage(trimmed))
    }

    private static func isTransientFailureMessage(_ message: String) -> Bool {
        guard !message.isEmpty else { return false }

        if message.hasPrefix("Cloud transcription failed:") {
            return true
        }
        if message.hasPrefix("Whisper error:") {
            return true
        }
        if message.hasPrefix("Whisper finalize timed out and was reset.") {
            return true
        }

        return false
    }
}
