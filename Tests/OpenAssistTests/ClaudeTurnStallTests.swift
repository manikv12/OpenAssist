import XCTest
@testable import OpenAssist

@MainActor
final class ClaudeTurnStallTests: XCTestCase {
    // MARK: - Happy path

    func testSuccessfulResultCancelsStallWatchdogAndResolvesCompleted() async throws {
        let runtime = CodexAssistantRuntime()
        runtime.beginClaudeTurnForTesting()

        let awaiter = runtime.awaitClaudeTurnCompletionForTesting()
        // Give the awaiter a tick to register its continuation.
        await Task.yield()
        XCTAssertEqual(runtime.pendingClaudeTurnContinuationCountForTesting, 1)

        // Inject a real terminal `result` event.
        runtime.processClaudeCodeOutputLineForTesting(#"""
        {"type":"result","subtype":"success","is_error":false,"result":"hi","stop_reason":"end_turn","session_id":"test-session"}
        """#)

        let status = try await awaiter.value
        XCTAssertEqual(status, .completed)
        XCTAssertEqual(runtime.pendingClaudeTurnContinuationCountForTesting, 0)
        XCTAssertFalse(
            runtime.claudeTurnStallWatchdogIsArmedForTesting,
            "Watchdog should be disarmed after completion"
        )
    }

    // MARK: - Stall watchdog

    func testStallWatchdogFireResolvesContinuationAsFailed() async throws {
        let runtime = CodexAssistantRuntime()
        runtime.beginClaudeTurnForTesting()

        let awaiter = runtime.awaitClaudeTurnCompletionForTesting()
        await Task.yield()
        XCTAssertEqual(runtime.pendingClaudeTurnContinuationCountForTesting, 1)

        // Fire synthetic stall directly — we don't want to wait 5 real minutes.
        runtime.fireClaudeTurnStallForTesting()

        do {
            _ = try await awaiter.value
            XCTFail("Expected stall watchdog to resolve the continuation with a failure")
        } catch let error as CodexAssistantRuntimeError {
            switch error {
            case .requestFailed(let message):
                XCTAssertTrue(
                    message.contains("stopped streaming"),
                    "Expected stall message, got: \(message)"
                )
            default:
                XCTFail("Expected requestFailed, got \(error)")
            }
        }
        XCTAssertEqual(runtime.pendingClaudeTurnContinuationCountForTesting, 0)
    }

    func testStallWatchdogMessageMentionsToolWhenToolInFlight() async throws {
        let runtime = CodexAssistantRuntime()
        runtime.beginClaudeTurnForTesting(awaitingTool: true)

        let awaiter = runtime.awaitClaudeTurnCompletionForTesting()
        await Task.yield()

        runtime.fireClaudeTurnStallForTesting(awaitingTool: true, timeoutNanos: 600_000_000_000)

        do {
            _ = try await awaiter.value
            XCTFail("Expected failure")
        } catch let error as CodexAssistantRuntimeError {
            if case .requestFailed(let message) = error {
                XCTAssertTrue(
                    message.contains("tool was running"),
                    "Tool-in-flight stall message should mention the tool: \(message)"
                )
            } else {
                XCTFail("Expected requestFailed, got \(error)")
            }
        }
    }

    // MARK: - Termination safety net

    func testStaleProcessTerminationDrainsPendingContinuation() async throws {
        let runtime = CodexAssistantRuntime()
        runtime.beginClaudeTurnForTesting()

        let awaiter = runtime.awaitClaudeTurnCompletionForTesting()
        await Task.yield()
        XCTAssertEqual(runtime.pendingClaudeTurnContinuationCountForTesting, 1)

        // Simulate the "no current process or active turn" fallback path.
        runtime.configureSessionForTesting(sessionID: "test-session", turnID: nil)
        runtime.simulateClaudeStaleProcessTerminationForTesting()

        do {
            _ = try await awaiter.value
            XCTFail("Expected safety-net drain to surface an error")
        } catch let error as CodexAssistantRuntimeError {
            if case .requestFailed(let message) = error {
                XCTAssertTrue(
                    message.contains("Claude Code exited"),
                    "Expected exit message, got: \(message)"
                )
            } else {
                XCTFail("Expected requestFailed, got \(error)")
            }
        }
        XCTAssertEqual(runtime.pendingClaudeTurnContinuationCountForTesting, 0)
    }

    func testStaleProcessTerminationDoesNotDrainPendingContinuationWhenReplacementProcessExists() async throws {
        let runtime = CodexAssistantRuntime()
        runtime.beginClaudeTurnForTesting()
        runtime.installActiveClaudeProcessForTesting()

        let awaiter = runtime.awaitClaudeTurnCompletionForTesting()
        await Task.yield()
        XCTAssertEqual(runtime.pendingClaudeTurnContinuationCountForTesting, 1)

        runtime.simulateClaudeStaleProcessTerminationForTesting()

        XCTAssertEqual(
            runtime.pendingClaudeTurnContinuationCountForTesting,
            1,
            "A stale subprocess exit must not fail the healthy replacement turn"
        )

        runtime.fireClaudeTurnStallForTesting()
        _ = try? await awaiter.value
    }

    func testPermissionStateChangeReschedulesStallWatchdogWithoutNewOutput() async throws {
        let runtime = CodexAssistantRuntime()
        runtime.beginClaudeTurnForTesting()

        let awaiter = runtime.awaitClaudeTurnCompletionForTesting()
        await Task.yield()

        runtime.processClaudeCodeOutputLineForTesting(#"""
        {"type":"system","session_id":"test-session"}
        """#)
        let generationBeforePermission = runtime.claudeTurnStallWatchdogGenerationForTesting

        runtime.setPendingPermissionForTesting(true)
        let generationWhileWaiting = runtime.claudeTurnStallWatchdogGenerationForTesting
        XCTAssertGreaterThan(
            generationWhileWaiting,
            generationBeforePermission,
            "Entering permission wait should reschedule the stall watchdog"
        )

        runtime.setPendingPermissionForTesting(false)
        XCTAssertGreaterThan(
            runtime.claudeTurnStallWatchdogGenerationForTesting,
            generationWhileWaiting,
            "Leaving permission wait should reschedule the stall watchdog again"
        )

        runtime.fireClaudeTurnStallForTesting()
        _ = try? await awaiter.value
    }

    func testToolStateChangeReschedulesStallWatchdogWithoutNewOutput() async throws {
        let runtime = CodexAssistantRuntime()
        runtime.beginClaudeTurnForTesting()

        let awaiter = runtime.awaitClaudeTurnCompletionForTesting()
        await Task.yield()

        runtime.processClaudeCodeOutputLineForTesting(#"""
        {"type":"system","session_id":"test-session"}
        """#)
        let generationBeforeTool = runtime.claudeTurnStallWatchdogGenerationForTesting

        runtime.setAwaitingToolExecutionForTesting(true)
        let generationWhileAwaitingTool = runtime.claudeTurnStallWatchdogGenerationForTesting
        XCTAssertGreaterThan(
            generationWhileAwaitingTool,
            generationBeforeTool,
            "Entering tool execution wait should reschedule the stall watchdog"
        )

        runtime.setAwaitingToolExecutionForTesting(false)
        XCTAssertGreaterThan(
            runtime.claudeTurnStallWatchdogGenerationForTesting,
            generationWhileAwaitingTool,
            "Leaving tool execution wait should reschedule the stall watchdog again"
        )

        runtime.fireClaudeTurnStallForTesting()
        _ = try? await awaiter.value
    }

    // MARK: - Rate limit event does not reset watchdog

    func testRateLimitEventDoesNotResetStallWatchdog() async throws {
        let runtime = CodexAssistantRuntime()
        runtime.beginClaudeTurnForTesting()

        let awaiter = runtime.awaitClaudeTurnCompletionForTesting()
        await Task.yield()

        // A regular inbound event arms the watchdog.
        runtime.processClaudeCodeOutputLineForTesting(#"""
        {"type":"system","session_id":"test-session"}
        """#)
        XCTAssertTrue(
            runtime.claudeTurnStallWatchdogIsArmedForTesting,
            "Watchdog should be armed after a real inbound event"
        )

        let watchdogGenerationBefore = runtime.claudeTurnStallWatchdogGenerationForTesting
        runtime.processClaudeCodeOutputLineForTesting(#"""
        {"type":"rate_limit_event","session_id":"test-session"}
        """#)
        let watchdogGenerationAfter = runtime.claudeTurnStallWatchdogGenerationForTesting
        XCTAssertEqual(
            watchdogGenerationBefore,
            watchdogGenerationAfter,
            "rate_limit_event must not reset the stall watchdog"
        )

        // Clean up pending continuation so the test doesn't leak.
        runtime.fireClaudeTurnStallForTesting()
        _ = try? await awaiter.value
    }
}
