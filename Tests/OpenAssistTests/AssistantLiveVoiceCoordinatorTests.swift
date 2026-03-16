import Combine
import XCTest
@testable import OpenAssist

@MainActor
private final class MockLiveVoiceStore: AssistantLiveVoiceSessionStore {
    var interactionMode: AssistantInteractionMode = .conversational
    var canStartConversation = true
    var hasActiveTurn = false
    var selectedSessionID: String? = "session-1" {
        didSet { selectedSessionIDSubject.send(selectedSessionID) }
    }
    var pendingPermissionRequest: AssistantPermissionRequest? {
        didSet { pendingPermissionRequestSubject.send(pendingPermissionRequest) }
    }
    var modeSwitchSuggestion: AssistantModeSwitchSuggestion? {
        didSet { modeSwitchSuggestionSubject.send(modeSwitchSuggestion) }
    }
    var assistantVoicePlaybackActive = false {
        didSet { assistantVoicePlaybackActiveSubject.send(assistantVoicePlaybackActive) }
    }
    var hudState: AssistantHUDState = .idle {
        didSet { hudStateSubject.send(hudState) }
    }
    var liveVoiceSessionSnapshot = AssistantLiveVoiceSessionSnapshot()

    let pendingPermissionRequestSubject = CurrentValueSubject<AssistantPermissionRequest?, Never>(nil)
    let modeSwitchSuggestionSubject = CurrentValueSubject<AssistantModeSwitchSuggestion?, Never>(nil)
    let assistantVoicePlaybackActiveSubject = CurrentValueSubject<Bool, Never>(false)
    let hudStateSubject = CurrentValueSubject<AssistantHUDState, Never>(.idle)
    let selectedSessionIDSubject = CurrentValueSubject<String?, Never>("session-1")

    private(set) var sentPrompts: [String] = []
    private(set) var appliedModeSwitchChoices: [AssistantModeSwitchChoice] = []
    private(set) var stopPlaybackCalls = 0

    var pendingPermissionRequestPublisher: AnyPublisher<AssistantPermissionRequest?, Never> {
        pendingPermissionRequestSubject.eraseToAnyPublisher()
    }

    var modeSwitchSuggestionPublisher: AnyPublisher<AssistantModeSwitchSuggestion?, Never> {
        modeSwitchSuggestionSubject.eraseToAnyPublisher()
    }

    var assistantVoicePlaybackActivePublisher: AnyPublisher<Bool, Never> {
        assistantVoicePlaybackActiveSubject.eraseToAnyPublisher()
    }

    var hudStatePublisher: AnyPublisher<AssistantHUDState, Never> {
        hudStateSubject.eraseToAnyPublisher()
    }

    var selectedSessionIDPublisher: AnyPublisher<String?, Never> {
        selectedSessionIDSubject.eraseToAnyPublisher()
    }

    func sendPrompt(_ prompt: String) async {
        sentPrompts.append(prompt)
        hasActiveTurn = true
    }

    func applyModeSwitchSuggestion(_ choice: AssistantModeSwitchChoice) async {
        appliedModeSwitchChoices.append(choice)
        interactionMode = choice.mode
        hasActiveTurn = true
    }

    func stopAssistantVoicePlayback() {
        stopPlaybackCalls += 1
        assistantVoicePlaybackActive = false
    }

    func updateLiveVoiceSessionSnapshot(_ snapshot: AssistantLiveVoiceSessionSnapshot) {
        liveVoiceSessionSnapshot = snapshot
    }
}

@MainActor
final class AssistantLiveVoiceCoordinatorTests: XCTestCase {
    private func makePermissionRequest() -> AssistantPermissionRequest {
        AssistantPermissionRequest(
            id: 1,
            sessionID: "session-1",
            toolTitle: "Run command",
            toolKind: "commandExecution",
            rationale: "This turn needs approval.",
            options: [
                AssistantPermissionOption(
                    id: "acceptForSession",
                    title: "Allow",
                    kind: nil,
                    isDefault: true
                )
            ],
            userInputQuestions: [],
            rawPayloadSummary: nil
        )
    }

    private func blockedAgenticSuggestion() -> AssistantModeSwitchSuggestion {
        AssistantModeSwitchSuggestion(
            source: .blocked,
            originMode: .conversational,
            message: "Needs stronger tool access.",
            choices: [
                AssistantModeSwitchChoice(
                    mode: .agentic,
                    title: "Switch & Retry in Agentic",
                    resendLastRequest: true
                )
            ]
        )
    }

    private func pumpMainRunLoop(iterations: Int = 4) async {
        for _ in 0..<iterations {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            await Task.yield()
        }
    }

    func testStartLiveVoiceSessionBeginsListeningInConversationalMode() async {
        let store = MockLiveVoiceStore()
        var startCaptureCalls = 0
        let coordinator = AssistantLiveVoiceCoordinator(
            store: store,
            startCapture: {
                startCaptureCalls += 1
                return true
            },
            stopCapture: {},
            cancelCapture: {},
            playbackResumeDelayNanoseconds: 0,
            interruptResumeDelayNanoseconds: 0
        )

        coordinator.startLiveVoiceSession(surface: .compactHUD)
        await pumpMainRunLoop()

        XCTAssertEqual(startCaptureCalls, 1)
        XCTAssertEqual(store.interactionMode, .conversational)
        XCTAssertEqual(store.liveVoiceSessionSnapshot.phase, .listening)
        XCTAssertEqual(store.liveVoiceSessionSnapshot.surface, .compactHUD)
        XCTAssertTrue(store.liveVoiceSessionSnapshot.isHandsFreeLoopEnabled)
    }

    func testBlockedModeSuggestionAutoPromotesToAgenticAndRetries() async {
        let store = MockLiveVoiceStore()
        let coordinator = AssistantLiveVoiceCoordinator(
            store: store,
            startCapture: { true },
            stopCapture: {},
            cancelCapture: {},
            playbackResumeDelayNanoseconds: 0,
            interruptResumeDelayNanoseconds: 0
        )

        coordinator.startLiveVoiceSession(surface: .mainWindow)
        await pumpMainRunLoop()

        coordinator.handleFinalTranscript("Run the test suite.")
        await pumpMainRunLoop()
        XCTAssertEqual(store.sentPrompts, ["Run the test suite."])

        store.modeSwitchSuggestion = blockedAgenticSuggestion()
        await pumpMainRunLoop()

        XCTAssertEqual(store.appliedModeSwitchChoices.count, 1)
        XCTAssertEqual(store.appliedModeSwitchChoices.first?.mode, .agentic)
        XCTAssertEqual(store.liveVoiceSessionSnapshot.interactionMode, .agentic)
    }

    func testStopSpeakingResumesListeningAfterPlaybackStops() async {
        let store = MockLiveVoiceStore()
        var startCaptureCalls = 0
        let coordinator = AssistantLiveVoiceCoordinator(
            store: store,
            startCapture: {
                startCaptureCalls += 1
                return true
            },
            stopCapture: {},
            cancelCapture: {},
            playbackResumeDelayNanoseconds: 0,
            interruptResumeDelayNanoseconds: 0
        )

        coordinator.startLiveVoiceSession(surface: .mainWindow)
        await pumpMainRunLoop()
        let playbackStopCallsBeforeInterrupt = store.stopPlaybackCalls

        store.assistantVoicePlaybackActive = true
        await pumpMainRunLoop()
        XCTAssertEqual(store.liveVoiceSessionSnapshot.phase, .speaking)

        coordinator.stopSpeakingAndResumeListening()
        await pumpMainRunLoop()

        XCTAssertEqual(store.stopPlaybackCalls - playbackStopCallsBeforeInterrupt, 1)
        XCTAssertEqual(startCaptureCalls, 2)
        XCTAssertEqual(store.liveVoiceSessionSnapshot.phase, .listening)
    }

    func testPermissionRequestPausesAndResumesAfterPlaybackFinishes() async {
        let store = MockLiveVoiceStore()
        var startCaptureCalls = 0
        let coordinator = AssistantLiveVoiceCoordinator(
            store: store,
            startCapture: {
                startCaptureCalls += 1
                return true
            },
            stopCapture: {},
            cancelCapture: {},
            playbackResumeDelayNanoseconds: 0,
            interruptResumeDelayNanoseconds: 0
        )

        coordinator.startLiveVoiceSession(surface: .compactHUD)
        await pumpMainRunLoop()

        store.pendingPermissionRequest = makePermissionRequest()
        await pumpMainRunLoop()
        XCTAssertEqual(store.liveVoiceSessionSnapshot.phase, .waitingForPermission)

        store.hasActiveTurn = true
        store.pendingPermissionRequest = nil
        await pumpMainRunLoop()
        XCTAssertEqual(store.liveVoiceSessionSnapshot.phase, .sending)
        XCTAssertEqual(startCaptureCalls, 1)

        store.assistantVoicePlaybackActive = true
        await pumpMainRunLoop()
        XCTAssertEqual(store.liveVoiceSessionSnapshot.phase, .speaking)

        store.assistantVoicePlaybackActive = false
        await pumpMainRunLoop()
        XCTAssertEqual(startCaptureCalls, 2)
        XCTAssertEqual(store.liveVoiceSessionSnapshot.phase, .listening)
    }

    func testEndingLiveVoiceSessionStopsLoopAndCancelsCapture() async {
        let store = MockLiveVoiceStore()
        var cancelCaptureCalls = 0
        let coordinator = AssistantLiveVoiceCoordinator(
            store: store,
            startCapture: { true },
            stopCapture: {},
            cancelCapture: { cancelCaptureCalls += 1 },
            playbackResumeDelayNanoseconds: 0,
            interruptResumeDelayNanoseconds: 0
        )

        coordinator.startLiveVoiceSession(surface: .mainWindow)
        await pumpMainRunLoop()
        XCTAssertEqual(store.liveVoiceSessionSnapshot.phase, .listening)

        coordinator.endLiveVoiceSession()
        await pumpMainRunLoop()

        XCTAssertEqual(cancelCaptureCalls, 1)
        XCTAssertEqual(store.liveVoiceSessionSnapshot.phase, .ended)
        XCTAssertFalse(store.liveVoiceSessionSnapshot.isHandsFreeLoopEnabled)
    }

    func testPlaybackFinishWaitsBeforeListeningAgain() async {
        let store = MockLiveVoiceStore()
        var startCaptureCalls = 0
        let coordinator = AssistantLiveVoiceCoordinator(
            store: store,
            startCapture: {
                startCaptureCalls += 1
                return true
            },
            stopCapture: {},
            cancelCapture: {},
            playbackResumeDelayNanoseconds: 50_000_000,
            interruptResumeDelayNanoseconds: 0
        )

        coordinator.startLiveVoiceSession(surface: .mainWindow)
        await pumpMainRunLoop()
        XCTAssertEqual(startCaptureCalls, 1)

        store.assistantVoicePlaybackActive = true
        await pumpMainRunLoop()
        XCTAssertEqual(store.liveVoiceSessionSnapshot.phase, .speaking)

        store.assistantVoicePlaybackActive = false
        await pumpMainRunLoop(iterations: 1)

        XCTAssertEqual(startCaptureCalls, 1)
        XCTAssertEqual(store.liveVoiceSessionSnapshot.phase, .paused)

        try? await Task.sleep(nanoseconds: 80_000_000)
        await pumpMainRunLoop()

        XCTAssertEqual(startCaptureCalls, 2)
        XCTAssertEqual(store.liveVoiceSessionSnapshot.phase, .listening)
    }
}
