import AppKit

@MainActor
protocol AssistantCompactPresenter: AnyObject {
    var isEnabled: Bool { get set }
    var currentScreen: NSScreen? { get }

    func setPresentationStyle(_ style: AssistantCompactPresentationStyle)
    func setPreferredScreen(_ screen: NSScreen?)
    func showFollowUp(for session: AssistantSessionSummary)
    func update(state: AssistantHUDState)
    func updateLevel(_ level: Float)
    func setVoiceRecording(_ isRecording: Bool)
    func receiveVoiceTranscript(_ text: String)
    func hide()
}

enum AssistantCompactDisplayAnchorMode: Equatable {
    case hardwareNotch
    case syntheticNotch
}
