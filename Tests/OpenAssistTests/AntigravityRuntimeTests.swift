import XCTest
@testable import OpenAssist

@MainActor
final class AntigravityRuntimeTests: XCTestCase {
    func testSendPromptRunsAntigravityPrintCommandAndPublishesReply() async throws {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("OpenAssistAntigravityRuntime-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let argumentsLogURL = temporaryDirectory.appendingPathComponent("arguments.txt")
        let fakeExecutableURL = temporaryDirectory.appendingPathComponent("agy")
        let fakeExecutable = """
        #!/bin/zsh
        printf '%s\\n' "$@" > "\(argumentsLogURL.path)"
        print -- "Fake Antigravity reply"
        """
        try fakeExecutable.write(to: fakeExecutableURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeExecutableURL.path)

        let runtime = CodexAssistantRuntime()
        runtime.backend = .antigravityCLI
        let recorder = LockedAntigravityRuntimeRecorder()
        runtime.onTranscriptMutation = { mutation in
            if case .upsert(let entry, _) = mutation, entry.role == .assistant {
                recorder.setAssistantText(entry.text)
            }
        }
        runtime.onTurnCompletion = { status in
            recorder.setCompletionStatus(status)
        }

        _ = try await runtime.refreshEnvironment(codexPath: fakeExecutableURL.path)
        _ = try await runtime.startNewSession(cwd: temporaryDirectory.path)
        try await runtime.sendPrompt("Say hello from Antigravity")
        await runtime.stop()

        let snapshot = recorder.snapshot()
        XCTAssertEqual(snapshot.assistantText, "Fake Antigravity reply")
        XCTAssertEqual(snapshot.completionStatus, .completed)

        let loggedArguments = try String(contentsOf: argumentsLogURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        XCTAssertEqual(Array(loggedArguments.prefix(6)), [
            "--print",
            "--sandbox",
            "--print-timeout",
            "20m",
            "--add-dir",
            temporaryDirectory.path
        ])
        XCTAssertTrue(loggedArguments.last?.contains("Say hello from Antigravity") ?? false)
        XCTAssertFalse(loggedArguments.contains("--dangerously-skip-permissions"))
    }
}

private final class LockedAntigravityRuntimeRecorder: @unchecked Sendable {
    struct Snapshot {
        let assistantText: String?
        let completionStatus: AssistantTurnCompletionStatus?
    }

    private let lock = NSLock()
    private var assistantText: String?
    private var completionStatus: AssistantTurnCompletionStatus?

    func setAssistantText(_ text: String) {
        lock.lock()
        assistantText = text
        lock.unlock()
    }

    func setCompletionStatus(_ status: AssistantTurnCompletionStatus) {
        lock.lock()
        completionStatus = status
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            assistantText: assistantText,
            completionStatus: completionStatus
        )
    }
}
