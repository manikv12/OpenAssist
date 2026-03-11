import Foundation
import XCTest
@testable import OpenAssist

final class ClaudeHookInstallerTests: XCTestCase {
    func testInstallerCreatesSettingsFileWithSelectedHooks() throws {
        let settingsURL = makeSettingsURL()
        let installer = ClaudeHookInstaller(settingsURL: settingsURL)

        let result = try installer.installSelectedHooks(
            [.stop, .subagentStop],
            port: 45831,
            token: "ks_test_token"
        )

        XCTAssertEqual(result.changedCount, 2)
        XCTAssertEqual(result.unchangedCount, 0)
        XCTAssertNil(result.backupURL)

        let rootObject = try loadJSONObject(at: settingsURL)
        let hooksObject = try XCTUnwrap(rootObject["hooks"] as? [String: Any])

        XCTAssertNil(hooksObject["Notification"])
        XCTAssertEqual((hooksObject["Stop"] as? [Any])?.count, 1)
        XCTAssertEqual((hooksObject["SubagentStop"] as? [Any])?.count, 1)

        let stopHook = try extractInnerHook(named: "Stop", from: hooksObject)
        XCTAssertEqual(stopHook["type"] as? String, "http")
        XCTAssertEqual(
            stopHook["url"] as? String,
            "http://127.0.0.1:45831/automation/v1/hooks/claude"
        )
    }

    func testInstallerPreservesExistingSettingsAndReplacesOldOpenAssistHook() throws {
        let settingsURL = makeSettingsURL()
        let original = """
        {
          "permissions": {
            "allow": ["Bash"]
          },
          "hooks": {
            "Stop": [
              {
                "hooks": [
                  {
                    "type": "http",
                    "url": "http://127.0.0.1:45831/automation/v1/hooks/claude",
                    "headers": {
                      "Authorization": "Bearer ks_old_token"
                    }
                  }
                ]
              },
              {
                "hooks": [
                  {
                    "type": "http",
                    "url": "https://example.com/external-hook"
                  }
                ]
              }
            ]
          }
        }
        """
        try writeJSON(original, to: settingsURL)

        let installer = ClaudeHookInstaller(settingsURL: settingsURL)
        let result = try installer.installSelectedHooks(
            [.stop],
            port: 45831,
            token: "ks_new_token"
        )

        XCTAssertEqual(result.changedCount, 1)
        XCTAssertEqual(result.unchangedCount, 0)
        XCTAssertNotNil(result.backupURL)

        let rootObject = try loadJSONObject(at: settingsURL)
        let permissionsObject = try XCTUnwrap(rootObject["permissions"] as? [String: Any])
        XCTAssertEqual(permissionsObject["allow"] as? [String], ["Bash"])

        let hooksObject = try XCTUnwrap(rootObject["hooks"] as? [String: Any])
        let stopEntries = try XCTUnwrap(hooksObject["Stop"] as? [Any])
        XCTAssertEqual(stopEntries.count, 2)

        let updatedManagedHook = try extractInnerHook(from: stopEntries[0])
        let externalHook = try extractInnerHook(from: stopEntries[1])

        XCTAssertEqual(updatedManagedHook["type"] as? String, "http")
        XCTAssertEqual(
            (updatedManagedHook["headers"] as? [String: String])?["Authorization"],
            "Bearer ks_new_token"
        )
        XCTAssertEqual(externalHook["url"] as? String, "https://example.com/external-hook")
    }

    func testInstallerDoesNotDuplicateHookWhenItAlreadyMatches() throws {
        let settingsURL = makeSettingsURL()
        let original = """
        {
          "hooks": {
            "Notification": [
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "curl -sS -X POST http://127.0.0.1:45831/automation/v1/hooks/claude -H 'Content-Type: application/json' -H 'Authorization: Bearer ks_ready_token' --data @-"
                  }
                ]
              }
            ]
          }
        }
        """
        try writeJSON(original, to: settingsURL)

        let installer = ClaudeHookInstaller(settingsURL: settingsURL)
        let result = try installer.installSelectedHooks(
            [.notification],
            port: 45831,
            token: "ks_ready_token"
        )

        XCTAssertEqual(result.changedCount, 0)
        XCTAssertEqual(result.unchangedCount, 1)
        XCTAssertNil(result.backupURL)

        let rootObject = try loadJSONObject(at: settingsURL)
        let hooksObject = try XCTUnwrap(rootObject["hooks"] as? [String: Any])
        XCTAssertEqual((hooksObject["Notification"] as? [Any])?.count, 1)
    }

    func testInstalledOptionsReadsExistingOpenAssistHooks() throws {
        let settingsURL = makeSettingsURL()
        let original = """
        {
          "hooks": {
            "Notification": [
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "curl -sS -X POST http://127.0.0.1:45831/automation/v1/hooks/claude -H 'Content-Type: application/json' -H 'Authorization: Bearer ks_ready_token' --data @-"
                  }
                ]
              }
            ],
            "Stop": [
              {
                "hooks": [
                  {
                    "type": "http",
                    "url": "http://127.0.0.1:45831/automation/v1/hooks/claude",
                    "headers": {
                      "Authorization": "Bearer ks_ready_token"
                    }
                  }
                ]
              }
            ],
            "SubagentStop": [
              {
                "hooks": [
                  {
                    "type": "http",
                    "url": "https://example.com/external-hook"
                  }
                ]
              }
            ]
          }
        }
        """
        try writeJSON(original, to: settingsURL)

        let installer = ClaudeHookInstaller(settingsURL: settingsURL)
        let installedOptions = try installer.installedOptions()

        XCTAssertEqual(installedOptions, [.notification, .stop])
    }

    private func makeSettingsURL() -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        return directoryURL
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
    }

    private func writeJSON(_ json: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(json.utf8).write(to: url)
    }

    private func loadJSONObject(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }

    private func extractInnerHook(named eventName: String, from hooksObject: [String: Any]) throws -> [String: Any] {
        let entries = try XCTUnwrap(hooksObject[eventName] as? [Any])
        return try extractInnerHook(from: entries[0])
    }

    private func extractInnerHook(from entry: Any) throws -> [String: Any] {
        let wrapper = try XCTUnwrap(entry as? [String: Any])
        let hooks = try XCTUnwrap(wrapper["hooks"] as? [Any])
        return try XCTUnwrap(hooks.first as? [String: Any])
    }
}
