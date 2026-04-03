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

    func testParseClaudeCodeInvocationFromStreamJSONIgnoresControlRequests() throws {
        let result = try CodexAssistantRuntime.parseClaudeCodeInvocationResult(from: """
        {"type":"system","session_id":"session-123"}
        {"type":"control_request","request_id":"req-1","request":{"subtype":"can_use_tool","tool_name":"Bash","tool_use_id":"tool-1","input":{"command":"git status"}}}
        {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"}},"session_id":"session-123"}
        {"type":"result","subtype":"success","is_error":false,"result":"Hello world","stop_reason":"end_turn","session_id":"session-123"}
        """)

        XCTAssertEqual(result.sessionID, "session-123")
        XCTAssertEqual(result.responseText, "Hello world")
        XCTAssertEqual(result.stopReason, "end_turn")
    }

    func testParseClaudeCodeInvocationFormatsOverloadedAPIError() {
        XCTAssertThrowsError(
            try CodexAssistantRuntime.parseClaudeCodeInvocationResult(from: """
            {
              "type": "result",
              "subtype": "success",
              "is_error": true,
              "result": "API Error: 529 {\\"type\\":\\"error\\",\\"error\\":{\\"type\\":\\"overloaded_error\\",\\"message\\":\\"Overloaded\\"},\\"request_id\\":\\"req_123\\"}",
              "session_id": "session-123"
            }
            """)
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                """
                Claude is overloaded right now.
                Please wait a little and try again.
                Request ID: req_123
                """
            )
        }
    }

    func testParseClaudeCodeInvocationFormatsServerErrorText() throws {
        let result = try CodexAssistantRuntime.parseClaudeCodeInvocationResult(from: """
        {
          "type": "result",
          "subtype": "success",
          "is_error": false,
          "result": "API Error: 500 {\\"type\\":\\"error\\",\\"error\\":{\\"type\\":\\"api_error\\",\\"message\\":\\"Internal server error\\"},\\"request_id\\":\\"req_456\\"}",
          "session_id": "session-123"
        }
        """)

        XCTAssertEqual(
            result.responseText,
            """
            Claude had a temporary server error.
            Please try again in a moment.
            Request ID: req_456
            """
        )
    }

    func testParseClaudeCodeInvocationFormatsExecutionErrorsArray() {
        XCTAssertThrowsError(
            try CodexAssistantRuntime.parseClaudeCodeInvocationResult(from: """
            {
              "type": "result",
              "subtype": "error_during_execution",
              "is_error": true,
              "session_id": "session-123",
              "errors": [
                "No conversation found with session ID: 6a4b33a6-839f-4803-9043-af9d913e9516"
              ]
            }
            """)
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "No conversation found with session ID: 6a4b33a6-839f-4803-9043-af9d913e9516"
            )
        }
    }

    @MainActor
    func testClaudeCodeUserMessagePayloadMatchesSDKFormat() {
        let runtime = CodexAssistantRuntime()
        let payload = runtime.claudeCodeUserMessagePayloadForTesting(content: "Read this file")

        XCTAssertEqual(payload["type"] as? String, "user")
        XCTAssertEqual(payload["session_id"] as? String, "")
        XCTAssertEqual((payload["message"] as? [String: Any])?["role"] as? String, "user")
        XCTAssertEqual((payload["message"] as? [String: Any])?["content"] as? String, "Read this file")
    }

    @MainActor
    func testClaudeCodeElicitationContentCoercesBooleanAndArrayValues() {
        let runtime = CodexAssistantRuntime()
        let content = runtime.claudeCodeElicitationContentForTesting(
            answers: [
                "confirm": ["Yes"],
                "targets": ["dev, prod"]
            ],
            requestedSchema: [
                "type": "object",
                "properties": [
                    "confirm": ["type": "boolean"],
                    "targets": [
                        "type": "array",
                        "items": ["type": "string"]
                    ]
                ]
            ]
        )

        XCTAssertEqual(content["confirm"] as? Bool, true)
        XCTAssertEqual(content["targets"] as? [String], ["dev", "prod"])
    }

    func testClaudeCodePlanModeUsesNativePermissionMode() {
        XCTAssertEqual(CodexAssistantRuntime.claudeCodePermissionMode(for: .plan), "plan")
        XCTAssertEqual(CodexAssistantRuntime.claudeCodePermissionMode(for: .agentic), "bypassPermissions")
    }
}
