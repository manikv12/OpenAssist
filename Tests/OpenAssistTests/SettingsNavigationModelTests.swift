import XCTest
@testable import OpenAssist

final class SettingsNavigationModelTests: XCTestCase {
    func testGettingStartedSearchRoutesToAssistantChecklist() throws {
        let entry = try XCTUnwrap(searchEntry(matchingTitle: "Setup checklist", query: "getting started"))

        XCTAssertEqual(entry.destination.section, .assistant)
        XCTAssertEqual(entry.destination.cardID, "gettingStarted.checklist")
    }

    func testTelegramSearchRoutesToIntegrationsTelegramPage() throws {
        let entry = try XCTUnwrap(searchEntry(matchingTitle: "Telegram remote", query: "telegram"))

        XCTAssertEqual(entry.destination.section, .integrations)
        XCTAssertEqual(entry.destination.cardID, "integrations.telegram.setup")
        XCTAssertEqual(entry.destination.advancedPage, .telegramRemote)
    }

    func testBrowserProfileSearchRoutesToAutomationPage() throws {
        let entry = try XCTUnwrap(searchEntry(matchingTitle: "Browser profile", query: "browser profile"))

        XCTAssertEqual(entry.destination.section, .automation)
        XCTAssertEqual(entry.destination.cardID, "automation.browserProfile")
    }

    func testWhisperSearchRoutesToVoiceAndDictation() throws {
        let entry = try XCTUnwrap(searchEntry(matchingTitle: "Whisper model library", query: "whisper"))

        XCTAssertEqual(entry.destination.section, .voiceDictation)
        XCTAssertEqual(entry.destination.cardID, "speech.modelLibrary")
    }

    func testAIStudioSearchRoutesToModelsAndConnections() throws {
        let entry = try XCTUnwrap(searchEntry(matchingTitle: "Models and connections", query: "AI Studio"))

        XCTAssertEqual(entry.destination.section, .modelsConnections)
        XCTAssertEqual(entry.destination.cardID, "models.connections")
    }

    func testPermissionsSearchRoutesToPrivacyPermissionsSection() throws {
        let entry = try XCTUnwrap(searchEntry(matchingTitle: "Permission overview", query: "permissions"))

        XCTAssertEqual(entry.destination.section, .privacyPermissions)
        XCTAssertEqual(entry.destination.cardID, "permissions.overview")
    }

    func testAgentShortcutSearchRoutesToVoiceAndDictation() throws {
        let entry = try XCTUnwrap(searchEntry(matchingTitle: "Agent shortcut", query: "agent shortcut"))

        XCTAssertEqual(entry.destination.section, .voiceDictation)
        XCTAssertEqual(entry.destination.cardID, "shortcuts.agentShortcut")
    }

    func testWhisperSectionFilterIncludesVoiceAndDictation() {
        let sections = SettingsNavigationModel.filteredSections(for: "whisper")

        XCTAssertTrue(sections.contains(.voiceDictation))
    }

    func testBrowserSectionFilterIncludesAutomation() {
        let sections = SettingsNavigationModel.filteredSections(for: "browser profile")

        XCTAssertTrue(sections.contains(.automation))
    }

    func testAssistantMemorySearchRoutesToAssistantSection() throws {
        let entry = try XCTUnwrap(searchEntry(matchingTitle: "Assistant memory", query: "assistant memory"))

        XCTAssertEqual(entry.destination.section, .assistant)
        XCTAssertEqual(entry.destination.cardID, "assistant.memory")
    }

    func testToolLimitsSearchRoutesToAssistantAdvanced() throws {
        let entry = try XCTUnwrap(searchEntry(matchingTitle: "Assistant advanced", query: "tool limits"))

        XCTAssertEqual(entry.destination.section, .assistant)
        XCTAssertEqual(entry.destination.cardID, "assistant.advanced")
    }

    func testLocalAPISearchRoutesToAutomationLocalAPI() throws {
        let entry = try XCTUnwrap(searchEntry(matchingTitle: "Automation local API", query: "local api"))

        XCTAssertEqual(entry.destination.section, .automation)
        XCTAssertEqual(entry.destination.cardID, "automation.localAPI")
    }

    private func searchEntry(matchingTitle title: String, query: String) -> SettingSearchEntry? {
        SettingsNavigationModel
            .filteredSearchEntries(for: query)
            .first(where: { $0.title == title })
    }
}
