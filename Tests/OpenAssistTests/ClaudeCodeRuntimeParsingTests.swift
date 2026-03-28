import XCTest
@testable import OpenAssist

final class ClaudeCodeRuntimeParsingTests: XCTestCase {
    func testParseClaudeCodeAccountSnapshot() throws {
        let snapshot = try CodexAssistantRuntime.parseClaudeCodeAccountSnapshot(from: """
        {
          "loggedIn": true,
          "authMethod": "claude.ai",
          "apiProvider": "firstParty",
          "email": "dev@example.com",
          "orgName": "Example Org",
          "subscriptionType": "team"
        }
        """)

        XCTAssertTrue(snapshot.isLoggedIn)
        XCTAssertEqual(snapshot.email, "dev@example.com")
        XCTAssertEqual(snapshot.planType, "team")
    }

    func testParseSignedOutClaudeCodeAccountSnapshot() throws {
        let snapshot = try CodexAssistantRuntime.parseClaudeCodeAccountSnapshot(from: """
        {
          "loggedIn": false
        }
        """)

        XCTAssertEqual(snapshot, .signedOut)
    }

    func testParseClaudeCodeInvocationUsageAndContextWindow() throws {
        let result = try CodexAssistantRuntime.parseClaudeCodeInvocationResult(from: """
        {
          "type": "result",
          "subtype": "success",
          "is_error": false,
          "result": "hi",
          "stop_reason": "end_turn",
          "session_id": "8b07968e-158f-4e3b-9f1f-b4f861d97e89",
          "usage": {
            "input_tokens": 3,
            "cache_creation_input_tokens": 5258,
            "cache_read_input_tokens": 11108,
            "output_tokens": 4
          },
          "modelUsage": {
            "claude-sonnet-4-6": {
              "inputTokens": 3,
              "outputTokens": 4,
              "cacheReadInputTokens": 11108,
              "cacheCreationInputTokens": 5258,
              "contextWindow": 200000
            }
          }
        }
        """)

        XCTAssertEqual(result.sessionID, "8b07968e-158f-4e3b-9f1f-b4f861d97e89")
        XCTAssertEqual(result.responseText, "hi")
        XCTAssertEqual(result.stopReason, "end_turn")
        XCTAssertEqual(result.modelContextWindow, 200000)
        XCTAssertEqual(
            result.usage,
            TokenUsageBreakdown(
                inputTokens: 16_369,
                outputTokens: 4,
                cachedInputTokens: 11_108,
                reasoningOutputTokens: 0,
                totalTokens: 16_373
            )
        )
    }

    func testParseClaudeCodeInvocationFromStructuredResult() throws {
        let result = try CodexAssistantRuntime.parseClaudeCodeInvocationResult(from: """
        {
          "type": "result",
          "subtype": "success",
          "is_error": false,
          "result": {
            "content": [
              { "text": "Hello" },
              { "content": { "text": "World" } }
            ]
          },
          "session_id": "session-123"
        }
        """)

        XCTAssertEqual(result.sessionID, "session-123")
        XCTAssertEqual(result.responseText, "Hello\nWorld")
        XCTAssertNil(result.usage)
    }

    func testParseClaudeCodeInvocationFromStreamJSONResult() throws {
        let result = try CodexAssistantRuntime.parseClaudeCodeInvocationResult(from: """
        {"type":"system","session_id":"session-123"}
        {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"}},"session_id":"session-123"}
        {"type":"result","subtype":"success","is_error":false,"result":"Hello world","stop_reason":"end_turn","session_id":"session-123","usage":{"input_tokens":3,"cache_creation_input_tokens":10,"cache_read_input_tokens":0,"output_tokens":4}}
        """)

        XCTAssertEqual(result.sessionID, "session-123")
        XCTAssertEqual(result.responseText, "Hello world")
        XCTAssertEqual(result.stopReason, "end_turn")
        XCTAssertEqual(
            result.usage,
            TokenUsageBreakdown(
                inputTokens: 13,
                outputTokens: 4,
                cachedInputTokens: 0,
                reasoningOutputTokens: 0,
                totalTokens: 17
            )
        )
    }

    func testClaudeCodePlanModeUsesNativePermissionMode() {
        XCTAssertEqual(CodexAssistantRuntime.claudeCodePermissionMode(for: .plan), "plan")
        XCTAssertEqual(CodexAssistantRuntime.claudeCodePermissionMode(for: .agentic), "bypassPermissions")
    }
}
