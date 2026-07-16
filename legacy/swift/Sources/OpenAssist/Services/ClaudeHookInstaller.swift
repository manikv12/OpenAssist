import Foundation

enum ClaudeHookInstallOption: String, CaseIterable, Hashable, Identifiable {
    case notification
    case stop
    case subagentStop

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .notification:
            return "Notification"
        case .stop:
            return "Stop"
        case .subagentStop:
            return "SubagentStop"
        }
    }

    var detailText: String {
        switch self {
        case .notification:
            return "Optional. Claude only supports this event through its command format. Open Assist adds that part for you automatically."
        case .stop:
            return "Alerts when the main Claude task finishes."
        case .subagentStop:
            return "Alerts when a Claude subagent finishes."
        }
    }

    var eventName: String {
        switch self {
        case .notification:
            return "Notification"
        case .stop:
            return "Stop"
        case .subagentStop:
            return "SubagentStop"
        }
    }

    fileprivate var sortOrder: Int {
        switch self {
        case .notification:
            return 2
        case .stop:
            return 0
        case .subagentStop:
            return 1
        }
    }
}

struct ClaudeHookInstallResult: Equatable {
    let changedCount: Int
    let unchangedCount: Int
    let settingsURL: URL
    let backupURL: URL?
}

enum ClaudeHookInstallerError: LocalizedError, Equatable {
    case missingToken
    case invalidSettingsFormat
    case invalidHooksFormat
    case invalidEventHooksFormat(String)

    var errorDescription: String? {
        switch self {
        case .missingToken:
            return "Open Assist could not find the Automation API token."
        case .invalidSettingsFormat:
            return "Claude settings.json is not a JSON object."
        case .invalidHooksFormat:
            return "Claude settings.json has an invalid hooks section."
        case .invalidEventHooksFormat(let eventName):
            return "Claude settings.json has invalid hooks for \(eventName)."
        }
    }
}

struct ClaudeHookInstaller {
    private let settingsURL: URL
    private let fileManager: FileManager

    init(
        settingsURL: URL = Self.defaultSettingsURL(),
        fileManager: FileManager = .default
    ) {
        self.settingsURL = settingsURL
        self.fileManager = fileManager
    }

    static func defaultSettingsURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
    }

    func installedOptions() throws -> Set<ClaudeHookInstallOption> {
        let rootObject = try loadSettingsObject()
        let hooksObject = try loadHooksObject(from: rootObject)
        var installed: Set<ClaudeHookInstallOption> = []

        for option in ClaudeHookInstallOption.allCases {
            let entries = try loadEventEntries(for: option, from: hooksObject)
            if entries.contains(where: { Self.isManagedEntry($0, for: option) }) {
                installed.insert(option)
            }
        }

        return installed
    }

    func installSelectedHooks(
        _ options: Set<ClaudeHookInstallOption>,
        port: UInt16,
        token: String
    ) throws -> ClaudeHookInstallResult {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            throw ClaudeHookInstallerError.missingToken
        }

        let selectedOptions = options.sorted { $0.sortOrder < $1.sortOrder }
        guard !selectedOptions.isEmpty else {
            return ClaudeHookInstallResult(
                changedCount: 0,
                unchangedCount: 0,
                settingsURL: settingsURL,
                backupURL: nil
            )
        }

        var rootObject = try loadSettingsObject()
        var hooksObject = try loadHooksObject(from: rootObject)
        var changedCount = 0
        var unchangedCount = 0

        for option in selectedOptions {
            let desiredEntry = Self.managedHookEntry(
                for: option,
                port: port,
                token: trimmedToken
            )
            let currentEntries = try loadEventEntries(for: option, from: hooksObject)
            let updatedEntries = Self.replacingManagedEntries(
                in: currentEntries,
                for: option,
                with: desiredEntry
            )

            if Self.jsonObjectsEqual(currentEntries, updatedEntries) {
                unchangedCount += 1
            } else {
                changedCount += 1
                hooksObject[option.eventName] = updatedEntries
            }
        }

        guard changedCount > 0 else {
            return ClaudeHookInstallResult(
                changedCount: 0,
                unchangedCount: unchangedCount,
                settingsURL: settingsURL,
                backupURL: nil
            )
        }

        rootObject["hooks"] = hooksObject
        let outputData = try Self.prettyPrintedJSONData(for: rootObject)

        try fileManager.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let backupURL: URL?
        if fileManager.fileExists(atPath: settingsURL.path) {
            backupURL = settingsURL
                .deletingLastPathComponent()
                .appendingPathComponent("settings.json.openassist-backup-\(Self.backupTimestamp())")
            try fileManager.copyItem(at: settingsURL, to: backupURL!)
        } else {
            backupURL = nil
        }

        try outputData.write(to: settingsURL, options: .atomic)

        return ClaudeHookInstallResult(
            changedCount: changedCount,
            unchangedCount: unchangedCount,
            settingsURL: settingsURL,
            backupURL: backupURL
        )
    }

    private func loadSettingsObject() throws -> [String: Any] {
        guard fileManager.fileExists(atPath: settingsURL.path) else {
            return [:]
        }

        let data = try Data(contentsOf: settingsURL)
        let jsonObject = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = jsonObject as? [String: Any] else {
            throw ClaudeHookInstallerError.invalidSettingsFormat
        }
        return dictionary
    }

    private func loadHooksObject(from rootObject: [String: Any]) throws -> [String: Any] {
        guard let hooksObject = rootObject["hooks"] else {
            return [:]
        }
        guard let dictionary = hooksObject as? [String: Any] else {
            throw ClaudeHookInstallerError.invalidHooksFormat
        }
        return dictionary
    }

    private func loadEventEntries(
        for option: ClaudeHookInstallOption,
        from hooksObject: [String: Any]
    ) throws -> [Any] {
        guard let existingValue = hooksObject[option.eventName] else {
            return []
        }
        guard let entries = existingValue as? [Any] else {
            throw ClaudeHookInstallerError.invalidEventHooksFormat(option.eventName)
        }
        return entries
    }

    private static func managedHookEntry(
        for option: ClaudeHookInstallOption,
        port: UInt16,
        token: String
    ) -> [String: Any] {
        [
            "hooks": [
                hookDefinition(
                    for: option,
                    port: port,
                    token: token
                )
            ]
        ]
    }

    private static func hookDefinition(
        for option: ClaudeHookInstallOption,
        port: UInt16,
        token: String
    ) -> [String: Any] {
        switch option {
        case .notification:
            return [
                "type": "command",
                "command": claudeNotificationCommand(port: port, token: token)
            ]
        case .stop, .subagentStop:
            return [
                "type": "http",
                "url": claudeHookURL(port: port),
                "headers": [
                    "Authorization": "Bearer \(token)"
                ]
            ]
        }
    }

    private static func claudeHookURL(port: UInt16) -> String {
        "http://127.0.0.1:\(Int(port))/automation/v1/hooks/claude"
    }

    private static func claudeNotificationCommand(port: UInt16, token: String) -> String {
        "curl -sS -X POST \(claudeHookURL(port: port)) -H 'Content-Type: application/json' -H 'Authorization: Bearer \(token)' --data @-"
    }

    private static func replacingManagedEntries(
        in entries: [Any],
        for option: ClaudeHookInstallOption,
        with desiredEntry: [String: Any]
    ) -> [Any] {
        var result: [Any] = []
        var insertedManagedEntry = false

        for entry in entries {
            if isManagedEntry(entry, for: option) {
                if !insertedManagedEntry {
                    result.append(desiredEntry)
                    insertedManagedEntry = true
                }
                continue
            }
            result.append(entry)
        }

        if !insertedManagedEntry {
            result.append(desiredEntry)
        }

        return result
    }

    private static func isManagedEntry(_ entry: Any, for option: ClaudeHookInstallOption) -> Bool {
        guard
            let wrapper = entry as? [String: Any],
            let hookEntries = wrapper["hooks"] as? [Any],
            hookEntries.count == 1,
            let hook = hookEntries.first as? [String: Any],
            let type = hook["type"] as? String
        else {
            return false
        }

        switch option {
        case .notification:
            guard type == "command", let command = hook["command"] as? String else {
                return false
            }
            return command.contains("/automation/v1/hooks/claude")
                && command.contains("127.0.0.1:")
        case .stop, .subagentStop:
            guard type == "http", let url = hook["url"] as? String else {
                return false
            }
            return url.contains("/automation/v1/hooks/claude")
                && url.contains("127.0.0.1:")
        }
    }

    private static func jsonObjectsEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        guard
            let lhsData = try? JSONSerialization.data(withJSONObject: lhs, options: [.sortedKeys]),
            let rhsData = try? JSONSerialization.data(withJSONObject: rhs, options: [.sortedKeys])
        else {
            return false
        }
        return lhsData == rhsData
    }

    private static func prettyPrintedJSONData(for object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        if data.last != 0x0A {
            data.append(0x0A)
        }
        return data
    }

    private static func backupTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
