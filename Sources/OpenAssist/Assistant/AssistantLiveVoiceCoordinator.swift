import Combine
import Foundation

enum AssistantLiveVoiceSessionPhase: String, Codable, Sendable {
    case idle
    case listening
    case transcribing
    case sending
    case waitingForPermission
    case speaking
    case paused
    case ended
}

enum AssistantLiveVoiceSessionSurface: String, Codable, Sendable {
    case mainWindow
    case compactHUD

    var displayName: String {
        switch self {
        case .mainWindow:
            return "Main Window"
        case .compactHUD:
            return "Orb / Notch"
        }
    }
}

struct AssistantLiveVoiceSessionSnapshot: Equatable, Sendable {
    var phase: AssistantLiveVoiceSessionPhase = .idle
    var surface: AssistantLiveVoiceSessionSurface = .mainWindow
    var interactionMode: AssistantInteractionMode = .agentic
    var isHandsFreeLoopEnabled = false
    var sessionID: String?
    var lastTranscript: String?
    var statusMessage: String?
    var lastError: String?
    var permissionRequest: AssistantPermissionRequest?

    var isActive: Bool {
        switch phase {
        case .idle, .ended:
            return false
        case .listening, .transcribing, .sending, .waitingForPermission, .speaking, .paused:
            return true
        }
    }

    var isListening: Bool { phase == .listening }
    var isSpeaking: Bool { phase == .speaking }
    var transcriptPreview: String? {
        guard let lastTranscript else { return nil }
        let normalized = lastTranscript
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        let limit = 96
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(limit - 1)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    var transcriptStatusText: String? {
        transcriptPreview.map { "Heard: \($0)" }
    }

    var displayText: String {
        if let lastError = lastError?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            return lastError
        }

        if let statusMessage = statusMessage?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            return statusMessage
        }

        switch phase {
        case .idle:
            return "Ready to start live voice."
        case .listening:
            return "Listening. Speak when you're ready."
        case .transcribing:
            return "Transcribing your turn..."
        case .sending:
            return interactionMode == .agentic
                ? "Sending your Agentic request..."
                : "Sending your request..."
        case .waitingForPermission:
            if let toolTitle = permissionRequest?.toolTitle.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
                return "Waiting for approval: \(toolTitle)."
            }
            return "Waiting for approval."
        case .speaking:
            return "Speaking the final reply. Use Stop Speaking to jump back in."
        case .paused:
            return "Live voice is paused."
        case .ended:
            return "Live voice ended."
        }
    }
}

@MainActor
protocol AssistantLiveVoiceSessionControlling: AnyObject {
    func startLiveVoiceSession(surface: AssistantLiveVoiceSessionSurface)
    func endLiveVoiceSession()
    func stopSpeakingAndResumeListening()
    func handleFinalTranscript(_ transcript: String)
    func handleAssistantReplyPlaybackFinished()
}

@MainActor
protocol AssistantLiveVoiceSessionStore: AnyObject {
    var interactionMode: AssistantInteractionMode { get set }
    var canStartConversation: Bool { get }
    var hasActiveTurn: Bool { get }
    var selectedSessionID: String? { get }
    var pendingPermissionRequest: AssistantPermissionRequest? { get }
    var modeSwitchSuggestion: AssistantModeSwitchSuggestion? { get }
    var assistantVoicePlaybackActive: Bool { get }
    var hudState: AssistantHUDState { get }
    var liveVoiceSessionSnapshot: AssistantLiveVoiceSessionSnapshot { get }

    var pendingPermissionRequestPublisher: AnyPublisher<AssistantPermissionRequest?, Never> { get }
    var modeSwitchSuggestionPublisher: AnyPublisher<AssistantModeSwitchSuggestion?, Never> { get }
    var assistantVoicePlaybackActivePublisher: AnyPublisher<Bool, Never> { get }
    var hudStatePublisher: AnyPublisher<AssistantHUDState, Never> { get }
    var selectedSessionIDPublisher: AnyPublisher<String?, Never> { get }

    func sendPrompt(_ prompt: String) async
    func applyModeSwitchSuggestion(_ choice: AssistantModeSwitchChoice) async
    func stopAssistantVoicePlayback()
    func updateLiveVoiceSessionSnapshot(_ snapshot: AssistantLiveVoiceSessionSnapshot)
}

@MainActor
final class AssistantLiveVoiceCoordinator: AssistantLiveVoiceSessionControlling {
    private enum Timing {
        static let playbackResumeDelayNanoseconds: UInt64 = 1_200_000_000
        static let interruptResumeDelayNanoseconds: UInt64 = 250_000_000
    }

    private let store: any AssistantLiveVoiceSessionStore
    private let startCapture: () -> Bool
    private let stopCapture: () -> Void
    private let cancelCapture: () -> Void
    private let playbackResumeDelayNanoseconds: UInt64
    private let interruptResumeDelayNanoseconds: UInt64
    private var cancellables = Set<AnyCancellable>()
    private var snapshot: AssistantLiveVoiceSessionSnapshot
    private var lastPlaybackActive = false
    private var isApplyingModeSwitchSuggestion = false
    private var pendingListeningResumeTask: Task<Void, Never>?
    private var nextPlaybackResumeDelayNanoseconds: UInt64?

    init(
        store: any AssistantLiveVoiceSessionStore,
        startCapture: @escaping () -> Bool,
        stopCapture: @escaping () -> Void,
        cancelCapture: @escaping () -> Void,
        playbackResumeDelayNanoseconds: UInt64 = Timing.playbackResumeDelayNanoseconds,
        interruptResumeDelayNanoseconds: UInt64 = Timing.interruptResumeDelayNanoseconds
    ) {
        self.store = store
        self.startCapture = startCapture
        self.stopCapture = stopCapture
        self.cancelCapture = cancelCapture
        self.playbackResumeDelayNanoseconds = playbackResumeDelayNanoseconds
        self.interruptResumeDelayNanoseconds = interruptResumeDelayNanoseconds
        self.snapshot = store.liveVoiceSessionSnapshot
        self.lastPlaybackActive = store.assistantVoicePlaybackActive
        bindStore()
        publish()
    }

    func startLiveVoiceSession(surface: AssistantLiveVoiceSessionSurface) {
        cancelPendingListeningResume()
        if snapshot.isActive {
            snapshot.surface = surface
            publish()
            if snapshot.phase == .paused {
                resumeListeningIfNeeded(message: "Listening. Speak when you're ready.")
            }
            return
        }

        guard store.canStartConversation else {
            snapshot = AssistantLiveVoiceSessionSnapshot(
                phase: .idle,
                surface: surface,
                interactionMode: .agentic,
                isHandsFreeLoopEnabled: false,
                sessionID: store.selectedSessionID,
                lastTranscript: nil,
                statusMessage: "Choose a model and make sure Codex is ready before starting live voice.",
                lastError: nil,
                permissionRequest: nil
            )
            publish()
            return
        }

        store.stopAssistantVoicePlayback()
        store.interactionMode = .agentic
        snapshot = AssistantLiveVoiceSessionSnapshot(
            phase: .paused,
            surface: surface,
            interactionMode: .agentic,
            isHandsFreeLoopEnabled: true,
            sessionID: store.selectedSessionID,
            lastTranscript: nil,
            statusMessage: "Starting live voice...",
            lastError: nil,
            permissionRequest: nil
        )
        publish()
        resumeListening(message: "Listening. Speak when you're ready.")
    }

    func endLiveVoiceSession() {
        cancelPendingListeningResume()
        nextPlaybackResumeDelayNanoseconds = nil
        if snapshot.isListening || snapshot.phase == .transcribing {
            cancelCapture()
        }

        if store.assistantVoicePlaybackActive {
            store.stopAssistantVoicePlayback()
        }

        snapshot.isHandsFreeLoopEnabled = false
        snapshot.permissionRequest = store.pendingPermissionRequest
        snapshot.phase = .ended
        snapshot.statusMessage = "Live voice ended."
        snapshot.lastError = nil
        publish()
    }

    func stopSpeakingAndResumeListening() {
        guard snapshot.isActive else { return }
        let wasSpeaking = store.assistantVoicePlaybackActive || snapshot.isSpeaking
        guard wasSpeaking else {
            resumeListeningIfNeeded(message: "Listening. Speak when you're ready.")
            return
        }

        snapshot.phase = .paused
        snapshot.statusMessage = "Stopping the spoken reply..."
        snapshot.lastError = nil
        publish()
        if store.assistantVoicePlaybackActive || lastPlaybackActive {
            nextPlaybackResumeDelayNanoseconds = interruptResumeDelayNanoseconds
            store.stopAssistantVoicePlayback()
        } else {
            scheduleListeningResume(
                afterNanoseconds: interruptResumeDelayNanoseconds,
                statusMessage: "Getting ready to listen again..."
            )
        }
    }

    func handleFinalTranscript(_ transcript: String) {
        cancelPendingListeningResume()
        guard snapshot.isActive || snapshot.phase == .transcribing else { return }

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            scheduleListeningResume(
                afterNanoseconds: 600_000_000,
                statusMessage: "I didn't catch that. Try again."
            )
            return
        }

        snapshot.lastTranscript = trimmed
        snapshot.phase = .sending
        snapshot.statusMessage = snapshot.interactionMode == .agentic
            ? "Sending your Agentic request..."
            : "Sending your request..."
        snapshot.lastError = nil
        publish()

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.store.sendPrompt(trimmed)
            guard self.snapshot.isActive,
                  self.snapshot.phase == .sending,
                  !self.store.hasActiveTurn,
                  self.store.pendingPermissionRequest == nil,
                  !self.store.assistantVoicePlaybackActive else {
                return
            }

            self.snapshot.phase = .paused
            self.snapshot.statusMessage = "The assistant could not start that live voice turn."
            self.snapshot.lastError = self.snapshot.statusMessage
            self.publish()
        }
    }

    func handleAssistantReplyPlaybackFinished() {
        guard snapshot.phase != .idle else { return }
        let resumeDelayNanoseconds = nextPlaybackResumeDelayNanoseconds ?? playbackResumeDelayNanoseconds
        nextPlaybackResumeDelayNanoseconds = nil
        scheduleListeningResume(
            afterNanoseconds: resumeDelayNanoseconds,
            statusMessage: "Getting ready to listen again..."
        )
    }

    func beginTranscribingTurn() {
        cancelPendingListeningResume()
        guard snapshot.isActive else { return }
        snapshot.phase = .transcribing
        snapshot.statusMessage = "Transcribing your turn..."
        snapshot.lastError = nil
        publish()
    }

    func handleCaptureFailure(_ message: String) {
        guard snapshot.isActive else { return }
        snapshot.phase = .paused
        snapshot.statusMessage = message
        snapshot.lastError = message
        publish()
    }

    func handleCaptureCancelled(message: String = "Live voice listening stopped.") {
        guard snapshot.isActive else { return }
        snapshot.phase = .paused
        snapshot.statusMessage = message
        snapshot.lastError = nil
        publish()
    }

    private func bindStore() {
        store.pendingPermissionRequestPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] request in
                self?.handlePermissionRequestChange(request)
            }
            .store(in: &cancellables)

        store.modeSwitchSuggestionPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] suggestion in
                self?.handleModeSwitchSuggestionChange(suggestion)
            }
            .store(in: &cancellables)

        store.assistantVoicePlaybackActivePublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] isActive in
                self?.handlePlaybackStateChange(isActive)
            }
            .store(in: &cancellables)

        store.hudStatePublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                self?.handleHUDStateChange(state)
            }
            .store(in: &cancellables)

        store.selectedSessionIDPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] sessionID in
                guard let self else { return }
                self.snapshot.sessionID = sessionID
                self.publish()
            }
            .store(in: &cancellables)
    }

    private func handlePermissionRequestChange(_ request: AssistantPermissionRequest?) {
        guard snapshot.isActive || snapshot.phase == .ended else { return }

        snapshot.permissionRequest = request

        if let request {
            cancelPendingListeningResume()
            snapshot.phase = .waitingForPermission
            snapshot.statusMessage = request.toolTitle.nonEmpty.map { "Waiting for approval: \($0)." }
                ?? "Waiting for approval."
            snapshot.lastError = nil
            publish()
            return
        }

        if snapshot.phase == .waitingForPermission {
            if store.assistantVoicePlaybackActive {
                snapshot.phase = .speaking
                snapshot.statusMessage = "Speaking the final reply..."
            } else if store.hasActiveTurn {
                snapshot.phase = .sending
                snapshot.statusMessage = snapshot.interactionMode == .agentic
                    ? "Continuing in Agentic mode..."
                    : "Continuing..."
            } else if snapshot.isHandsFreeLoopEnabled {
                resumeListening(message: "Listening. Speak when you're ready.")
                return
            }
            publish()
        }
    }

    private func handleModeSwitchSuggestionChange(_ suggestion: AssistantModeSwitchSuggestion?) {
        guard snapshot.isActive,
              snapshot.interactionMode == .conversational,
              !isApplyingModeSwitchSuggestion,
              let suggestion,
              suggestion.source == .blocked,
              suggestion.originMode == .conversational,
               let retryChoice = suggestion.choices.first(where: { $0.mode == .agentic && $0.resendLastRequest }) else {
            return
        }

        cancelPendingListeningResume()
        isApplyingModeSwitchSuggestion = true
        snapshot.interactionMode = .agentic
        snapshot.phase = .sending
        snapshot.statusMessage = "Retrying in Agentic mode..."
        snapshot.lastError = nil
        publish()

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.store.applyModeSwitchSuggestion(retryChoice)
            self.isApplyingModeSwitchSuggestion = false
            self.snapshot.interactionMode = .agentic
            if self.snapshot.phase != .waitingForPermission && !self.store.assistantVoicePlaybackActive {
                self.snapshot.phase = .sending
                self.snapshot.statusMessage = "Agentic live voice is active."
            }
            self.publish()
        }
    }

    private func handlePlaybackStateChange(_ isActive: Bool) {
        guard snapshot.isActive || snapshot.phase == .ended else {
            lastPlaybackActive = isActive
            return
        }

        defer { lastPlaybackActive = isActive }

        if isActive {
            cancelPendingListeningResume()
            snapshot.phase = .speaking
            snapshot.statusMessage = "Speaking the final reply..."
            snapshot.lastError = nil
            publish()
            return
        }

        if lastPlaybackActive {
            handleAssistantReplyPlaybackFinished()
        }
    }

    private func handleHUDStateChange(_ state: AssistantHUDState) {
        guard snapshot.isActive else { return }

        if state.phase == .failed,
           !store.assistantVoicePlaybackActive,
           store.pendingPermissionRequest == nil {
            let message = state.detail?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                ?? state.title.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                ?? "Live voice ran into an error."
            snapshot.phase = .paused
            snapshot.statusMessage = message
            snapshot.lastError = message
            publish()
            return
        }

        if state.phase == .idle,
           snapshot.phase == .sending,
           !store.hasActiveTurn,
           store.pendingPermissionRequest == nil,
           !store.assistantVoicePlaybackActive {
            scheduleListeningResume(
                afterNanoseconds: 600_000_000,
                statusMessage: "Getting ready to listen again..."
            )
        }
    }

    private func resumeListeningIfNeeded(message: String) {
        cancelPendingListeningResume()
        guard snapshot.isHandsFreeLoopEnabled else {
            if snapshot.phase != .ended {
                snapshot.phase = .paused
                snapshot.statusMessage = "Live voice is paused."
                publish()
            }
            return
        }

        guard store.pendingPermissionRequest == nil else {
            snapshot.phase = .waitingForPermission
            snapshot.permissionRequest = store.pendingPermissionRequest
            snapshot.statusMessage = snapshot.permissionRequest?.toolTitle.nonEmpty.map { "Waiting for approval: \($0)." }
                ?? "Waiting for approval."
            publish()
            return
        }

        resumeListening(message: message)
    }

    private func scheduleListeningResume(
        afterNanoseconds delayNanoseconds: UInt64,
        statusMessage: String
    ) {
        cancelPendingListeningResume()

        guard snapshot.isHandsFreeLoopEnabled else {
            if snapshot.phase != .ended {
                snapshot.phase = .paused
                snapshot.statusMessage = "Live voice is paused."
                publish()
            }
            return
        }

        snapshot.phase = .paused
        snapshot.statusMessage = statusMessage
        snapshot.lastError = nil
        nextPlaybackResumeDelayNanoseconds = nil
        publish()

        guard delayNanoseconds > 0 else {
            resumeListeningIfNeeded(message: "Listening. Speak when you're ready.")
            return
        }

        pendingListeningResumeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                return
            }

            self.pendingListeningResumeTask = nil

            guard self.snapshot.isActive,
                  self.snapshot.phase == .paused,
                  !self.store.assistantVoicePlaybackActive else {
                return
            }

            self.resumeListeningIfNeeded(message: "Listening. Speak when you're ready.")
        }
    }

    private func resumeListening(message: String) {
        snapshot.permissionRequest = nil
        snapshot.sessionID = store.selectedSessionID
        snapshot.lastError = nil
        snapshot.statusMessage = message
        if startCapture() {
            snapshot.phase = .listening
        } else {
            snapshot.phase = .paused
            snapshot.statusMessage = "Open Assist could not start live voice listening."
            snapshot.lastError = snapshot.statusMessage
        }
        publish()
    }

    private func publish() {
        store.updateLiveVoiceSessionSnapshot(snapshot)
    }

    private func cancelPendingListeningResume() {
        pendingListeningResumeTask?.cancel()
        pendingListeningResumeTask = nil
    }
}

@MainActor
extension AssistantStore: AssistantLiveVoiceSessionStore {
    var pendingPermissionRequestPublisher: AnyPublisher<AssistantPermissionRequest?, Never> {
        $pendingPermissionRequest.eraseToAnyPublisher()
    }

    var modeSwitchSuggestionPublisher: AnyPublisher<AssistantModeSwitchSuggestion?, Never> {
        $modeSwitchSuggestion.eraseToAnyPublisher()
    }

    var assistantVoicePlaybackActivePublisher: AnyPublisher<Bool, Never> {
        $assistantVoicePlaybackActive.eraseToAnyPublisher()
    }

    var hudStatePublisher: AnyPublisher<AssistantHUDState, Never> {
        $hudState.eraseToAnyPublisher()
    }

    var selectedSessionIDPublisher: AnyPublisher<String?, Never> {
        $selectedSessionID.eraseToAnyPublisher()
    }
}
