import XCTest
@testable import OpenAssist

final class LocalAutomationHelperTests: XCTestCase {
    func testBrowserOpenCommandArgumentsAlwaysIncludeSelectedProfile() {
        let profile = BrowserProfile(
            browser: .edge,
            directoryName: "Profile 2",
            displayName: "Work",
            gaiaName: nil
        )

        let arguments = LocalAutomationHelper.browserOpenCommandArguments(
            appPath: "/Applications/Microsoft Edge.app",
            profile: profile,
            url: URL(string: "https://example.com")!
        )

        XCTAssertEqual(
            arguments,
            [
                "-na",
                "/Applications/Microsoft Edge.app",
                "--args",
                "--profile-directory=Profile 2",
                "https://example.com"
            ]
        )
    }

    func testSystemSettingsURLRoutesCommonPanesAwayFromPrivacy() {
        XCTAssertEqual(
            LocalAutomationHelper.systemSettingsURL(for: "Wi-Fi")?.absoluteString,
            "x-apple.systempreferences:com.apple.Network-Settings.extension"
        )
        XCTAssertEqual(
            LocalAutomationHelper.systemSettingsURL(for: "Bluetooth")?.absoluteString,
            "x-apple.systempreferences:com.apple.BluetoothSettings"
        )
        XCTAssertEqual(
            LocalAutomationHelper.systemSettingsURL(for: "Displays")?.absoluteString,
            "x-apple.systempreferences:com.apple.Displays-Settings.extension"
        )
    }

    func testSystemSettingsURLKeepsPrivacyQueriesOnPrivacyPane() {
        XCTAssertEqual(
            LocalAutomationHelper.systemSettingsURL(for: "Screen Recording")?.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        )
    }
}
