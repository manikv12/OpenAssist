import Foundation
import XCTest
@testable import OpenAssist

final class CodexCommandRunnerTests: XCTestCase {
    func testRunProcessCollectsLargeOutputWithoutBlocking() async throws {
        let result = try await CodexCommandRunner.runProcess(
            commandName: "sh",
            arguments: ["-lc", "yes x | head -c 200000"]
        )

        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(result.output.count, 200000)
        XCTAssertEqual(String(data: result.output.prefix(3), encoding: .utf8), "x\nx")
    }
}
