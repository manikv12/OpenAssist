import XCTest
@testable import OpenAssist

final class AssistantShellExecutionServiceTests: XCTestCase {
    func testParseExecCommandRequestSupportsInteractiveOptions() throws {
        let request = try AssistantShellExecutionService.parseExecCommandRequest(
            from: [
                "cmd": "printf hello",
                "workdir": "/tmp",
                "shell": "/bin/bash",
                "login": false,
                "tty": true,
                "yield_time_ms": 25,
                "max_output_tokens": 1200
            ]
        )

        XCTAssertEqual(request.command, "printf hello")
        XCTAssertEqual(request.workingDirectory, "/tmp")
        XCTAssertEqual(request.shellPath, "/bin/bash")
        XCTAssertFalse(request.loginShell)
        XCTAssertTrue(request.interactive)
        XCTAssertEqual(request.yieldTimeMs, 25)
        XCTAssertEqual(request.maxOutputCharacters, 1200)
    }

    func testExecCommandCapturesOutput() async {
        let service = AssistantShellExecutionService()
        let result = await service.runCommand(
            threadID: "shell-test",
            arguments: [
                "cmd": "printf hello",
                "yield_time_ms": 20
            ],
            preferredModelID: nil
        )

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.summary.contains("Command"))
        XCTAssertTrue(result.contentItems.contains { $0.text?.contains("hello") == true })
    }
}
