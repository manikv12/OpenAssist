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

    func testCatalogHistorySupportExcludesCLIBackedSessions() {
        let cli = AssistantSessionSummary(
            id: "cli-1",
            title: "CLI",
            source: .cli,
            status: .active
        )
        let appServer = AssistantSessionSummary(
            id: "server-1",
            title: "Open Assist",
            source: .appServer,
            status: .completed
        )

        XCTAssertFalse(cli.supportsCatalogHistory)
        XCTAssertTrue(appServer.supportsCatalogHistory)
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

    func testProviderIndependentThreadPrefersActiveProviderBindingMetadata() {
        let summary = AssistantSessionSummary(
            id: "openassist-v2-thread",
            title: "V2",
            source: .openAssist,
            threadArchitectureVersion: .providerIndependentV2,
            activeProvider: .copilot,
            providerBindingsByBackend: [
                AssistantProviderBinding(
                    backend: .codex,
                    providerSessionID: "codex-1",
                    latestModelID: "gpt-5.4"
                ),
                AssistantProviderBinding(
                    backend: .copilot,
                    providerSessionID: "copilot-1",
                    latestModelID: "gemini-3-pro-preview"
                )
            ],
            status: .idle,
            latestModel: "legacy-model"
        )

        XCTAssertTrue(summary.isProviderIndependentThreadV2)
        XCTAssertEqual(summary.activeProviderBackend, .copilot)
        XCTAssertEqual(summary.activeProviderSessionID, "copilot-1")
        XCTAssertEqual(summary.modelID, "gemini-3-pro-preview")
    }

    func testSidebarShowsCurrentAndLegacyManagedSessionsWithHistory() {
        let legacyThread = AssistantSessionSummary(
            id: "openassist-legacy",
            title: "Legacy",
            source: .openAssist,
            threadArchitectureVersion: .legacy,
            status: .idle
        )
        let v2Thread = AssistantSessionSummary(
            id: "openassist-v2",
            title: "V2",
            source: .openAssist,
            threadArchitectureVersion: .providerIndependentV2,
            status: .idle,
            latestUserMessage: "hello"
        )
        let cliSession = AssistantSessionSummary(
            id: "copilot-legacy",
            title: "CLI",
            source: .cli,
            status: .idle,
            latestUserMessage: "hello"
        )
        let appServerSession = AssistantSessionSummary(
            id: "openassist-legacy-runtime",
            title: "Legacy runtime",
            source: .appServer,
            status: .completed,
            latestAssistantMessage: "done"
        )

        XCTAssertFalse(assistantSessionSupportsCurrentThreadUI(legacyThread))
        XCTAssertFalse(assistantShouldListSessionInSidebar(legacyThread, selectedSessionID: nil))
        XCTAssertTrue(assistantSessionSupportsCurrentThreadUI(v2Thread))
        XCTAssertTrue(assistantShouldListSessionInSidebar(v2Thread, selectedSessionID: nil))
        XCTAssertTrue(assistantSessionSupportsCurrentThreadUI(cliSession))
        XCTAssertTrue(assistantShouldListSessionInSidebar(cliSession, selectedSessionID: nil))
        XCTAssertTrue(assistantSessionSupportsCurrentThreadUI(appServerSession))
        XCTAssertTrue(assistantShouldListSessionInSidebar(appServerSession, selectedSessionID: nil))
    }

    func testEmptyProviderIndependentDraftIsHiddenUnlessSelected() {
        let emptyDraft = AssistantSessionSummary(
            id: "openassist-empty",
            title: "New Assistant Session",
            source: .openAssist,
            threadArchitectureVersion: .providerIndependentV2,
            status: .idle,
            summary: nil,
            latestUserMessage: nil,
            latestAssistantMessage: nil
        )
        let filledThread = AssistantSessionSummary(
            id: "openassist-filled",
            title: "Hi",
            source: .openAssist,
            threadArchitectureVersion: .providerIndependentV2,
            status: .completed,
            latestUserMessage: "Hello"
        )

        XCTAssertFalse(assistantShouldListSessionInSidebar(emptyDraft, selectedSessionID: nil))
        XCTAssertTrue(assistantShouldListSessionInSidebar(emptyDraft, selectedSessionID: emptyDraft.id))
        XCTAssertTrue(assistantShouldListSessionInSidebar(filledThread, selectedSessionID: nil))
    }

    func testCleanupSessionMergeKeepsRegistryBackedV2Threads() {
        let liveSession = AssistantSessionSummary(
            id: "openassist-live",
            title: "Live",
            source: .openAssist,
            threadArchitectureVersion: .providerIndependentV2,
            status: .idle
        )
        let catalogSession = AssistantSessionSummary(
            id: "catalog-openassist",
            title: "Catalog",
            source: .openAssist,
            threadArchitectureVersion: .legacy,
            status: .completed
        )
        let registrySession = AssistantSessionSummary(
            id: "openassist-v2-registry",
            title: "Registry",
            source: .openAssist,
            threadArchitectureVersion: .providerIndependentV2,
            status: .completed
        )

        let merged = assistantMergedSessionsForCleanup(
            liveSessions: [liveSession],
            catalogSessions: [catalogSession],
            registrySessions: [registrySession]
        )

        XCTAssertEqual(
            Set(merged.map(\.id)),
            Set(["openassist-live", "catalog-openassist", "openassist-v2-registry"])
        )
    }

    func testConversationPersistenceDefaultsToSnapshotOnlyForOlderSavedThreads() throws {
        let data = try JSONSerialization.data(
            withJSONObject: [
                "id": "openassist-old",
                "title": "Old",
                "source": "openAssist",
                "threadArchitectureVersion": 2,
                "status": "idle"
            ],
            options: [.sortedKeys]
        )

        let decoded = try JSONDecoder().decode(AssistantSessionSummary.self, from: data)
        XCTAssertEqual(decoded.conversationPersistence, .snapshotOnly)
        XCTAssertFalse(decoded.usesHybridConversationPersistence)
    }

    func testProviderIndependentHybridPersistenceFlagRequiresHybridSetting() {
        let hybrid = AssistantSessionSummary(
            id: "openassist-hybrid",
            title: "Hybrid",
            source: .openAssist,
            threadArchitectureVersion: .providerIndependentV2,
            conversationPersistence: .hybridJSONL,
            status: .idle
        )
        let snapshotOnly = AssistantSessionSummary(
            id: "openassist-snapshot",
            title: "Snapshot",
            source: .openAssist,
            threadArchitectureVersion: .providerIndependentV2,
            conversationPersistence: .snapshotOnly,
            status: .idle
        )

        XCTAssertTrue(hybrid.usesHybridConversationPersistence)
        XCTAssertFalse(snapshotOnly.usesHybridConversationPersistence)
    }
}
