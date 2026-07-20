import XCTest
@testable import OpenAssist

@MainActor
final class SettingsStoreTelegramSelectionTests: XCTestCase {
    private func makeIsolatedDefaults() -> UserDefaults {
        let suite = "OpenAssistTests.SettingsStore.Telegram.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Failed to create isolated defaults suite: \(suite)")
        }
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testTelegramSelectedSessionIDPersistsAcrossReload() {
        let defaults = makeIsolatedDefaults()
        let store = SettingsStore(defaults: defaults)

        store.telegramSelectedSessionID = "telegram-session-1"

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.telegramSelectedSessionID, "telegram-session-1")
    }

    func testClearingTelegramRemoteOwnerAlsoClearsSelectedSessionID() {
        let defaults = makeIsolatedDefaults()
        let store = SettingsStore(defaults: defaults)
        store.telegramSelectedSessionID = "telegram-session-2"

        store.clearTelegramRemoteOwner()

        XCTAssertEqual(store.telegramSelectedSessionID, "")
    }

    func testChangingTelegramBotTokenClearsSelectedSessionID() {
        let defaults = makeIsolatedDefaults()
        let store = SettingsStore(defaults: defaults)
        store.telegramBotToken = "token-a"
        store.telegramSelectedSessionID = "telegram-session-3"

        store.telegramBotToken = "token-b"

        XCTAssertEqual(store.telegramSelectedSessionID, "")
    }
}
