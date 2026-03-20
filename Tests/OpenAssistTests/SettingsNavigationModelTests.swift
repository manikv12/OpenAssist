import XCTest
@testable import OpenAssist

final class SettingsNavigationModelTests: XCTestCase {
    func testTelegramSearchRoutesToTelegramRemotePage() throws {
        let entry = try XCTUnwrap(searchEntry(matchingTitle: "Telegram remote", query: "telegram"))

        XCTAssertEqual(entry.destination.section, .automationRemote)
        XCTAssertEqual(entry.destination.automationPage, .telegramRemote)
    }

    func testBrowserProfileSearchRoutesToBrowserAndAppControlPage() throws {
        let entry = try XCTUnwrap(searchEntry(matchingTitle: "Browser profile", query: "browser profile"))

        XCTAssertEqual(entry.destination.section, .automationRemote)
        XCTAssertEqual(entry.destination.automationPage, .browserAndApps)
    }

    func testWhisperSearchRoutesToVoiceAndDictation() throws {
        let entry = try XCTUnwrap(searchEntry(matchingTitle: "Whisper model library", query: "whisper"))

        XCTAssertEqual(entry.destination.section, .voiceDictation)
        XCTAssertNil(entry.destination.automationPage)
    }

    func testAIStudioSearchRoutesToAssistantSection() throws {
        let entry = try XCTUnwrap(searchEntry(matchingTitle: "AI Studio", query: "AI Studio"))

        XCTAssertEqual(entry.destination.section, .assistant)
        XCTAssertNil(entry.destination.automationPage)
    }

    func testPermissionsSearchRoutesToAppPermissionsSection() throws {
        let entry = try XCTUnwrap(searchEntry(matchingTitle: "Permission overview", query: "permissions"))

        XCTAssertEqual(entry.destination.section, .appPermissions)
        XCTAssertNil(entry.destination.automationPage)
    }

    func testAgentShortcutSearchRoutesToAssistantSection() throws {
        let entry = try XCTUnwrap(searchEntry(matchingTitle: "Agent shortcut", query: "agent shortcut"))

        XCTAssertEqual(entry.destination.section, .assistant)
        XCTAssertNil(entry.destination.automationPage)
    }

    func testWhisperSectionFilterIncludesVoiceAndDictation() {
        let sections = SettingsNavigationModel.filteredSections(for: "whisper")

        XCTAssertTrue(sections.contains(.voiceDictation))
    }

    func testBrowserSectionFilterIncludesAutomationAndRemote() {
        let sections = SettingsNavigationModel.filteredSections(for: "browser profile")

        XCTAssertTrue(sections.contains(.automationRemote))
    }

    private func searchEntry(matchingTitle title: String, query: String) -> SettingSearchEntry? {
        SettingsNavigationModel
            .filteredSearchEntries(for: query)
            .first(where: { $0.title == title })
    }
}
