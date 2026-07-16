import AppKit

@MainActor
protocol AssistantCompactPresenter: AnyObject {
    var isEnabled: Bool { get set }
    var currentScreen: NSScreen? { get }
    var isExpandedSurfaceVisible: Bool { get }

    func setPresentationStyle(_ style: AssistantCompactPresentationStyle)
    func setPreferredScreen(_ screen: NSScreen?)
    func prepareVoiceCaptureComposer()
    func showFollowUp(for session: AssistantSessionSummary)
    func collapseExpandedSurface()
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
