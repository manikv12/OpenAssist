import XCTest
@testable import OpenAssist

final class AssistantSessionSummaryTests: XCTestCase {
    func testSubtitleFallsBackInExpectedPriorityOrder() {
        var summary = AssistantSessionSummary(
            id: "session-1",
            title: "Folder cleanup",
            source: .cli,
            status: .active,
            cwd: "/Users/test/Downloads",
            createdAt: nil,
            updatedAt: nil,
            summary: "Prepared a cleanup plan",
            latestModel: nil,
            latestUserMessage: "Please sort the files",
            latestAssistantMessage: "I found duplicate invoices"
        )

        XCTAssertEqual(summary.subtitle, "I found duplicate invoices")

        summary.latestAssistantMessage = nil
        XCTAssertEqual(summary.subtitle, "Prepared a cleanup plan")

        summary.summary = nil
        XCTAssertEqual(summary.subtitle, "Please sort the files")

        summary.latestUserMessage = nil
        XCTAssertEqual(summary.subtitle, "/Users/test/Downloads")

        summary.cwd = ""
        XCTAssertEqual(summary.subtitle, "No recent summary")
    }

    func testSourceLabelsMatchCurrentCodexSessionOrigins() {
        XCTAssertEqual(AssistantSessionSource.cli.label, "CLI")
        XCTAssertEqual(AssistantSessionSource.vscode.label, "VS Code")
        XCTAssertEqual(AssistantSessionSource.appServer.label, "Open Assist")
    }

    func testAllCurrentCodexSourcesAreTreatedAsLocalSessions() {
        let cli = AssistantSessionSummary(
            id: "cli-1",
            title: "CLI",
            source: .cli,
            status: .active
        )
        let vscode = AssistantSessionSummary(
            id: "vscode-1",
            title: "VS Code",
            source: .vscode,
            status: .waitingForApproval
        )
        let appServer = AssistantSessionSummary(
            id: "server-1",
            title: "Open Assist",
            source: .appServer,
            status: .completed
        )

        XCTAssertTrue(cli.isLocalSession)
        XCTAssertTrue(vscode.isLocalSession)
        XCTAssertTrue(appServer.isLocalSession)
    }

    func testStatusSupportsCurrentCodexSessionStates() {
        let approval = AssistantSessionSummary(
            id: "approval-1",
            title: "Approval",
            source: .vscode,
            status: .waitingForApproval
        )
        let input = AssistantSessionSummary(
            id: "input-1",
            title: "Input",
            source: .cli,
            status: .waitingForInput
        )
        let failed = AssistantSessionSummary(
            id: "failed-1",
            title: "Failed",
            source: .appServer,
            status: .failed
        )

        XCTAssertEqual(approval.status, .waitingForApproval)
        XCTAssertEqual(input.status, .waitingForInput)
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(approval.status.rawValue, "waitingForApproval")
        XCTAssertEqual(input.status.rawValue, "waitingForInput")
    }

    func testHUDShortLabelReflectsPhase() {
        let state = AssistantHUDState(phase: .waitingForPermission, title: "Permission needed", detail: "Write file")
        XCTAssertEqual(state.shortLabel, "Waiting")
    }
}
