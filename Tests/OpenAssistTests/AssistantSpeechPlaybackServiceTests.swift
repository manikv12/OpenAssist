import XCTest
@testable import OpenAssist

@MainActor
private final class MockAssistantSpeechProvider: AssistantSpeechProvider {
    let engine: AssistantSpeechEngine
    var hasActivePlayback = false
    var speakCallCount = 0
    var stopCallCount = 0
    var prewarmCallCount = 0
    var speakError: Error?
    var nextHealth = AssistantSpeechHealth(
        engine: .humeOctave,
        state: .healthy,
        detail: "Ready",
        checkedAt: Date(),
        model: "Test Voice",
        usesFallback: false,
        installRecommended: false
    )

    init(engine: AssistantSpeechEngine) {
        self.engine = engine
    }

    func speak(_ request: AssistantSpeechRequest) async throws {
        speakCallCount += 1
        if let speakError {
            throw speakError
        }
    }

    func stopCurrentPlayback() {
        stopCallCount += 1
        hasActivePlayback = false
    }

    func prewarmIfNeeded() async {
        prewarmCallCount += 1
    }

    func healthStatus() async -> AssistantSpeechHealth {
        nextHealth
    }

    func availableVoices() -> [AssistantSpeechVoiceOption] {
        [
            AssistantSpeechVoiceOption(id: "", name: "System Default", language: "")
        ]
    }
}

@MainActor
final class AssistantSpeechPlaybackServiceTests: XCTestCase {
    private struct VoiceSettingsSnapshot {
        let enabled: Bool
        let engineRawValue: String
        let humeVoiceID: String
        let humeVoiceName: String
        let humeVoiceSourceRawValue: String
        let fallbackToMacOS: Bool
        let fallbackVoiceIdentifier: String
        let interruptOnNewReply: Bool
    }

    private var settings: SettingsStore!
    private var snapshot: VoiceSettingsSnapshot!

    override func setUp() {
        super.setUp()
        settings = SettingsStore.shared
        snapshot = VoiceSettingsSnapshot(
            enabled: settings.assistantVoiceOutputEnabled,
            engineRawValue: settings.assistantVoiceEngineRawValue,
            humeVoiceID: settings.assistantHumeVoiceID,
            humeVoiceName: settings.assistantHumeVoiceName,
            humeVoiceSourceRawValue: settings.assistantHumeVoiceSourceRawValue,
            fallbackToMacOS: settings.assistantTTSFallbackToMacOS,
            fallbackVoiceIdentifier: settings.assistantTTSFallbackVoiceIdentifier,
            interruptOnNewReply: settings.assistantInterruptCurrentSpeechOnNewReply
        )
        settings.assistantVoiceOutputEnabled = true
        settings.assistantVoiceEngine = .humeOctave
        settings.assistantHumeVoiceID = "voice-1"
        settings.assistantHumeVoiceName = "Helpful Voice"
        settings.assistantHumeVoiceSource = .humeAI
        settings.assistantTTSFallbackToMacOS = true
        settings.assistantTTSFallbackVoiceIdentifier = ""
        settings.assistantInterruptCurrentSpeechOnNewReply = true
    }

    override func tearDown() {
        settings.assistantVoiceOutputEnabled = snapshot.enabled
        settings.assistantVoiceEngineRawValue = snapshot.engineRawValue
        settings.assistantHumeVoiceID = snapshot.humeVoiceID
        settings.assistantHumeVoiceName = snapshot.humeVoiceName
        settings.assistantHumeVoiceSourceRawValue = snapshot.humeVoiceSourceRawValue
        settings.assistantTTSFallbackToMacOS = snapshot.fallbackToMacOS
        settings.assistantTTSFallbackVoiceIdentifier = snapshot.fallbackVoiceIdentifier
        settings.assistantInterruptCurrentSpeechOnNewReply = snapshot.interruptOnNewReply
        snapshot = nil
        settings = nil
        super.tearDown()
    }

    func testRuntimeFinalWithPreviousStreamingItemTriggersSpeech() {
        let previous = AssistantTimelineItem.assistantFinal(
            id: "assistant-1",
            sessionID: "session-1",
            turnID: "turn-1",
            text: "Working",
            createdAt: Date(),
            isStreaming: true,
            source: .runtime
        )
        let incoming = AssistantTimelineItem.assistantFinal(
            id: "assistant-1",
            sessionID: "session-1",
            turnID: "turn-1",
            text: "Finished answer",
            createdAt: Date(),
            isStreaming: false,
            source: .runtime
        )

        XCTAssertTrue(
            AssistantSpeechTrigger.shouldAutoSpeak(
                incoming: incoming,
                existingItem: previous,
                featureEnabled: true,
                lastSpokenTimelineItemID: nil
            )
        )
    }

    func testHistoryReloadDoesNotTriggerSpeech() {
        let historyItem = AssistantTimelineItem.assistantFinal(
            id: "assistant-history",
            sessionID: "session-1",
            turnID: "turn-1",
            text: "Old answer",
            createdAt: Date(),
            isStreaming: false,
            source: .codexSession
        )

        XCTAssertFalse(
            AssistantSpeechTrigger.shouldAutoSpeak(
                incoming: historyItem,
                existingItem: nil,
                featureEnabled: true,
                lastSpokenTimelineItemID: nil
            )
        )
    }

    func testDuplicateFinalDoesNotTriggerSpeechTwice() {
        let existing = AssistantTimelineItem.assistantFinal(
            id: "assistant-dup",
            sessionID: "session-1",
            turnID: "turn-1",
            text: "Same answer",
            createdAt: Date(),
            isStreaming: false,
            source: .runtime
        )
        let incoming = AssistantTimelineItem.assistantFinal(
            id: "assistant-dup",
            sessionID: "session-1",
            turnID: "turn-1",
            text: "Same answer",
            createdAt: Date(),
            isStreaming: false,
            source: .runtime
        )

        XCTAssertFalse(
            AssistantSpeechTrigger.shouldAutoSpeak(
                incoming: incoming,
                existingItem: existing,
                featureEnabled: true,
                lastSpokenTimelineItemID: nil
            )
        )
        XCTAssertFalse(
            AssistantSpeechTrigger.shouldAutoSpeak(
                incoming: incoming,
                existingItem: nil,
                featureEnabled: true,
                lastSpokenTimelineItemID: "assistant-dup"
            )
        )
    }

    func testHumeFailureFallsBackToMacOSWhenEnabled() async throws {
        let hume = MockAssistantSpeechProvider(engine: .humeOctave)
        hume.speakError = AssistantSpeechError.serviceUnavailable("Hume offline")
        let macOS = MockAssistantSpeechProvider(engine: .macos)
        let service = AssistantSpeechPlaybackService(
            settings: settings,
            humeProvider: hume,
            macOSProvider: macOS
        )

        try await service.speak(
            text: "Hello from Open Assist",
            request: AssistantSpeechRequest(
                text: "Hello from Open Assist",
                sessionID: "session-1",
                turnID: "turn-1",
                timelineItemID: "assistant-1",
                preferredEngine: .humeOctave,
                fallbackPolicy: .macOS,
                timeout: 5,
                voicePromptReference: nil,
                promptText: nil
            )
        )

        XCTAssertEqual(hume.speakCallCount, 1)
        XCTAssertEqual(macOS.speakCallCount, 1)
    }

    func testMacOSEngineBypassesHumeProvider() async throws {
        let hume = MockAssistantSpeechProvider(engine: .humeOctave)
        let macOS = MockAssistantSpeechProvider(engine: .macos)
        let service = AssistantSpeechPlaybackService(
            settings: settings,
            humeProvider: hume,
            macOSProvider: macOS
        )

        try await service.speak(
            text: "Speak with macOS only",
            request: AssistantSpeechRequest(
                text: "Speak with macOS only",
                sessionID: "session-1",
                turnID: "turn-1",
                timelineItemID: "assistant-2",
                preferredEngine: .macos,
                fallbackPolicy: .disabled,
                timeout: 5,
                voicePromptReference: nil,
                promptText: nil
            )
        )

        XCTAssertEqual(hume.speakCallCount, 0)
        XCTAssertEqual(macOS.speakCallCount, 1)
    }

    func testNewReplySkipsWhenInterruptSettingIsOffAndAudioIsStillBusy() async throws {
        settings.assistantInterruptCurrentSpeechOnNewReply = false

        let hume = MockAssistantSpeechProvider(engine: .humeOctave)
        hume.hasActivePlayback = true
        let macOS = MockAssistantSpeechProvider(engine: .macos)
        let service = AssistantSpeechPlaybackService(
            settings: settings,
            humeProvider: hume,
            macOSProvider: macOS
        )

        try await service.speak(
            text: "Do not interrupt the current speech",
            request: AssistantSpeechRequest(
                text: "Do not interrupt the current speech",
                sessionID: "session-1",
                turnID: "turn-1",
                timelineItemID: "assistant-3",
                preferredEngine: .humeOctave,
                fallbackPolicy: .macOS,
                timeout: 5,
                voicePromptReference: nil,
                promptText: nil
            )
        )

        XCTAssertEqual(hume.stopCallCount, 0)
        XCTAssertEqual(hume.speakCallCount, 0)
        XCTAssertEqual(macOS.speakCallCount, 0)
    }
}
