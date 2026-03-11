import Foundation
import XCTest
@testable import OpenAssist

final class AutomationAPIModelsTests: XCTestCase {
    func testBearerAuthorizationParsesToken() {
        XCTAssertEqual(
            AutomationAPIAuthorization.bearerToken(from: "Bearer ks_test_token"),
            "ks_test_token"
        )
        XCTAssertTrue(
            AutomationAPIAuthorization.isAuthorized(
                authorizationHeader: "Bearer ks_test_token",
                expectedToken: "ks_test_token"
            )
        )
    }

    func testBearerAuthorizationRejectsMalformedHeader() {
        XCTAssertNil(AutomationAPIAuthorization.bearerToken(from: "Token ks_test_token"))
        XCTAssertNil(AutomationAPIAuthorization.bearerToken(from: "Bearer"))
        XCTAssertFalse(
            AutomationAPIAuthorization.isAuthorized(
                authorizationHeader: "Bearer ks_other",
                expectedToken: "ks_test_token"
            )
        )
    }

    func testAnnounceRequestDecodesAllPublicFields() throws {
        let payload = """
        {
          "message": "Build finished",
          "title": "Claude Code",
          "subtitle": "Task complete",
          "channels": ["notification", "speech"],
          "voiceIdentifier": "com.apple.voice.compact.en-US.Samantha",
          "sound": "processing",
          "source": "claude-code.stop",
          "dedupeKey": "session-123",
          "dedupeWindowSeconds": 45
        }
        """

        let decoded = try JSONDecoder().decode(AutomationAPIAnnounceRequest.self, from: Data(payload.utf8))

        XCTAssertEqual(decoded.message, "Build finished")
        XCTAssertEqual(decoded.title, "Claude Code")
        XCTAssertEqual(decoded.subtitle, "Task complete")
        XCTAssertEqual(decoded.channels, [.notification, .speech])
        XCTAssertEqual(decoded.voiceIdentifier, "com.apple.voice.compact.en-US.Samantha")
        XCTAssertEqual(decoded.sound, .processing)
        XCTAssertEqual(decoded.source, "claude-code.stop")
        XCTAssertEqual(decoded.dedupeKey, "session-123")
        XCTAssertEqual(decoded.dedupeWindowSeconds, 45)
    }

    func testRequestResolverRejectsDisabledRequestedChannel() {
        XCTAssertThrowsError(
            try AutomationAPIRequestResolver.resolveRequestedChannels(
                requestedChannels: [.notification, .speech],
                enabledChannels: [.notification]
            )
        ) { error in
            XCTAssertEqual(
                error as? AutomationAPIRequestError,
                .forbidden("Requested automation channel is disabled in Settings.")
            )
        }
    }

    func testSourceGateRejectsDisabledCodexCLI() {
        XCTAssertThrowsError(
            try AutomationAPISourceGate.validate(
                sourceIdentifier: "codex-cli.agent-turn-complete",
                enabledSources: [.claudeCode]
            )
        ) { error in
            XCTAssertEqual(
                error as? AutomationAPIRequestError,
                .forbidden("This automation source is disabled in Settings.")
            )
        }
    }

    func testNotificationPermittedChannelsDropsNotificationWhenDenied() {
        let resolved = AutomationAPIRequestResolver.notificationPermittedChannels(
            from: [.notification, .sound],
            notificationAuthorizationState: .denied
        )

        XCTAssertEqual(resolved, [.sound])
    }

    func testNotificationPermittedChannelsKeepsNotificationWhenAuthorized() {
        let resolved = AutomationAPIRequestResolver.notificationPermittedChannels(
            from: [.notification, .speech],
            notificationAuthorizationState: .authorized
        )

        XCTAssertEqual(resolved, [.notification, .speech])
    }

    func testDedupeStoreRejectsRepeatWithinWindow() {
        let store = AutomationAPIDedupeStore()
        let now = Date()

        XCTAssertFalse(
            store.shouldDedupe(
                key: "claude:notification:abc",
                now: now,
                windowSeconds: 15
            )
        )
        XCTAssertTrue(
            store.shouldDedupe(
                key: "claude:notification:abc",
                now: now.addingTimeInterval(5),
                windowSeconds: 15
            )
        )
        XCTAssertFalse(
            store.shouldDedupe(
                key: "claude:notification:abc",
                now: now.addingTimeInterval(20),
                windowSeconds: 15
            )
        )
    }

    func testHealthResponseBuilderIncludesSelectedVoice() {
        let voice = AutomationAPIVoiceOption(
            id: "voice-1",
            name: "Samantha",
            language: "en-US"
        )

        let response = AutomationAPIHealthResponse.make(
            serverState: "running",
            version: "1.0.0",
            bindAddress: "127.0.0.1",
            port: 45831,
            enabledChannels: [.notification, .speech],
            notificationPermission: .authorized,
            selectedVoice: voice,
            selectedSound: .processing
        )

        XCTAssertEqual(response.serverState, "running")
        XCTAssertEqual(response.version, "1.0.0")
        XCTAssertEqual(response.bindAddress, "127.0.0.1")
        XCTAssertEqual(response.port, 45831)
        XCTAssertEqual(response.enabledChannels, [.notification, .speech])
        XCTAssertEqual(response.notificationPermission, .authorized)
        XCTAssertEqual(response.selectedVoice, voice)
        XCTAssertEqual(response.selectedSound, .processing)
    }

    func testClaudeNotificationAdapterMapsFields() throws {
        let payload = """
        {
          "hook_event_name": "Notification",
          "message": "Here’s what I did:\\n- Build finished successfully.\\n- Let me know if you want the full diff.",
          "title": "Claude Code",
          "notification_type": "task_complete",
          "session_id": "session-123"
        }
        """

        let request = try ClaudeCodeHookAdapter.adapt(Data(payload.utf8))

        XCTAssertEqual(request.message, "Build finished successfully")
        XCTAssertEqual(request.title, "Claude Code")
        XCTAssertNil(request.subtitle)
        XCTAssertEqual(request.source, "claude-code.notification")
        XCTAssertEqual(request.dedupeWindowSeconds, 15)
        XCTAssertNil(request.channels)
        XCTAssertNil(request.sound)
    }

    func testClaudeNotificationAdapterUsesFriendlyIdlePromptText() throws {
        let payload = """
        {
          "hook_event_name": "Notification",
          "message": "Claude is idle.",
          "title": "Claude Code",
          "notification_type": "idle_prompt",
          "session_id": "session-123"
        }
        """

        let request = try ClaudeCodeHookAdapter.adapt(Data(payload.utf8))

        XCTAssertEqual(request.message, "Claude is waiting for your input.")
        XCTAssertEqual(request.title, "Claude Code")
        XCTAssertEqual(request.subtitle, "Ready for input")
        XCTAssertEqual(request.source, "claude-code.notification")
    }

    func testClaudeStopAdapterFallsBackWhenAssistantMessageMissing() throws {
        let payload = """
        {
          "hook_event_name": "Stop",
          "session_id": "session-456"
        }
        """

        let request = try ClaudeCodeHookAdapter.adapt(Data(payload.utf8))

        XCTAssertEqual(request.title, "Claude Code")
        XCTAssertNil(request.subtitle)
        XCTAssertEqual(request.message, "Claude Code finished.")
        XCTAssertEqual(request.source, "claude-code.stop")
        XCTAssertEqual(request.dedupeWindowSeconds, 30)
        XCTAssertNil(request.sound)
    }

    func testClaudeSubagentStopAdapterUsesSubagentDefaults() throws {
        let payload = """
        {
          "hook_event_name": "SubagentStop",
          "agent_id": "agent-42",
          "last_assistant_message": "Finished the worker task."
        }
        """

        let request = try ClaudeCodeHookAdapter.adapt(Data(payload.utf8))

        XCTAssertEqual(request.title, "Claude Code")
        XCTAssertNil(request.subtitle)
        XCTAssertEqual(request.message, "Finished the worker task")
        XCTAssertEqual(request.source, "claude-code.subagent-stop")
        XCTAssertEqual(request.dedupeWindowSeconds, 30)
        XCTAssertNil(request.sound)
    }

    func testClaudeStopAdapterCleansVerboseAssistantMessage() throws {
        let payload = """
        {
          "hook_event_name": "Stop",
          "session_id": "session-456",
          "last_assistant_message": "## Summary\\nI updated the Claude notification formatting so it is shorter and easier to read. Let me know if you want me to also add a HUD."
        }
        """

        let request = try ClaudeCodeHookAdapter.adapt(Data(payload.utf8))

        XCTAssertEqual(
            request.message,
            "Updated the Claude notification formatting so it is shorter and easier to read"
        )
        XCTAssertEqual(request.source, "claude-code.stop")
    }

    func testClaudeUnsupportedEventThrows() {
        let payload = """
        {
          "hook_event_name": "PreToolUse",
          "session_id": "session-789"
        }
        """

        XCTAssertThrowsError(try ClaudeCodeHookAdapter.adapt(Data(payload.utf8))) { error in
            XCTAssertEqual(
                error as? AutomationAPIRequestError,
                .unsupportedHookEvent("pretooluse")
            )
        }
    }

    func testCodexNotifyAdapterSupportsHyphenatedKeys() throws {
        let payload = """
        {
          "type": "agent-turn-complete",
          "turn-id": "turn-123",
          "input-messages": ["Explain the architecture"],
          "last-assistant-message": "I finished the explanation."
        }
        """

        let request = try CodexNotifyHookAdapter.adapt(Data(payload.utf8))

        XCTAssertEqual(request.title, "Codex CLI")
        XCTAssertEqual(request.subtitle, "Task complete")
        XCTAssertEqual(request.message, "I finished the explanation.")
        XCTAssertEqual(request.source, "codex-cli.agent-turn-complete")
        XCTAssertEqual(request.dedupeKey, "codex-cli:agent-turn-complete:turn-123")
        XCTAssertEqual(request.dedupeWindowSeconds, 30)
        XCTAssertNil(request.sound)
    }

    func testCodexNotifyAdapterSupportsUnderscoredKeysAndFallsBackToPrompt() throws {
        let payload = """
        {
          "type": "agent-turn-complete",
          "turn_id": "turn-456",
          "input_messages": ["Run the full test suite"],
          "last_assistant_message": ""
        }
        """

        let request = try CodexNotifyHookAdapter.adapt(Data(payload.utf8))

        XCTAssertEqual(request.message, "Completed: Run the full test suite")
        XCTAssertEqual(request.dedupeKey, "codex-cli:agent-turn-complete:turn-456")
    }

    func testCodexNotifyAdapterRejectsUnsupportedType() {
        let payload = """
        {
          "type": "agent-turn-started",
          "turn-id": "turn-999"
        }
        """

        XCTAssertThrowsError(try CodexNotifyHookAdapter.adapt(Data(payload.utf8))) { error in
            XCTAssertEqual(
                error as? AutomationAPIRequestError,
                .invalidRequest("Unsupported Codex notify event.")
            )
        }
    }
}
