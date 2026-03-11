import Foundation

enum DictationInputMode: Equatable {
    case idle
    case holdToTalk
    case continuous
}

enum DictationInputModeStateMachine {
    static func onHoldStart(_ mode: DictationInputMode) -> DictationInputMode {
        switch mode {
        case .idle:
            return .holdToTalk
        case .holdToTalk:
            return .holdToTalk
        case .continuous:
            return .continuous
        }
    }

    static func onHoldStop(_ mode: DictationInputMode) -> DictationInputMode {
        switch mode {
        case .holdToTalk:
            return .idle
        case .idle, .continuous:
            return mode
        }
    }

    static func onContinuousToggle(_ mode: DictationInputMode) -> DictationInputMode {
        switch mode {
        case .idle:
            return .continuous
        case .continuous:
            return .idle
        case .holdToTalk:
            return .holdToTalk
        }
    }

    static func onRecordingEnded(_ mode: DictationInputMode) -> DictationInputMode {
        switch mode {
        case .idle, .holdToTalk, .continuous:
            return .idle
        }
    }
}
