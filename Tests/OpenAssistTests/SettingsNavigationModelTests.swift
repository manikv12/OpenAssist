import XCTest
@testable import OpenAssist

final class SettingsNavigationModelTests: XCTestCase {
    func testGettingStartedSearchRoutesToGettingStartedHome() throws {
        let entry = try XCTUnwrap(searchEntry(matchingTitle: "Getting started", query: "getting started"))

        XCTAssertEqual(entry.destination.section, .gettingStarted)
        XCTAssertEqual(entry.destination.cardID, "gettingStarted.checklist")
    }

    func testTelegramSearchRoutesToAdvancedTelegramPage() throws {
        let entry = try XCTUnwrap(searchEntry(matchingTitle: "Telegram remote", query: "telegram"))

        XCTAssertEqual(entry.destination.section, .advanced)
        XCTAssertEqual(entry.destination.cardID, "integrations.telegram.setup")
        XCTAssertEqual(entry.destination.advancedPage, .telegramRemote)
    }

    func testBrowserProfileSearchRoutesToBrowserAndAppControlPage() throws {
        let entry = try XCTUnwrap(searchEntry(matchingTitle: "Browser profile", query: "browser profile"))

        XCTAssertEqual(entry.destination.section, .browserAppControl)
        XCTAssertEqual(entry.destination.cardID, "automation.browserProfile")
    }

    func testWhisperSearchRoutesToVoiceAndDictation() throws {
        let entry = try XCTUnwrap(searchEntry(matchingTitle: "Whisper model library", query: "whisper"))

        XCTAssertEqual(entry.destination.section, .voiceDictation)
        XCTAssertEqual(entry.destination.cardID, "speech.modelLibrary")
    }

    func testAIStudioSearchRoutesToAdvancedSection() throws {
        let entry = try XCTUnwrap(searchEntry(matchingTitle: "AI Studio", query: "AI Studio"))

        XCTAssertEqual(entry.destination.section, .advanced)
        XCTAssertEqual(entry.destination.cardID, "advanced.aiStudio")
    }

    func testPermissionsSearchRoutesToPermissionsPrivacySection() throws {
        let entry = try XCTUnwrap(searchEntry(matchingTitle: "Permission overview", query: "permissions"))

        XCTAssertEqual(entry.destination.section, .permissionsPrivacy)
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

    func testBrowserSectionFilterIncludesBrowserAndAppControl() {
        let sections = SettingsNavigationModel.filteredSections(for: "browser profile")

        XCTAssertTrue(sections.contains(.browserAppControl))
    }

    private func searchEntry(matchingTitle title: String, query: String) -> SettingSearchEntry? {
        SettingsNavigationModel
            .filteredSearchEntries(for: query)
            .first(where: { $0.title == title })
    }
}
