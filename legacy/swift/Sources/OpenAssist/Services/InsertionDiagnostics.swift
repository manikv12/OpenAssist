import Foundation

enum InsertionDiagnostics {
    static let defaultsEnabledKey = "OpenAssist.insertionDiagnosticsEnabled"
    private static let envEnabledKey = "OPENASSIST_INSERTION_DIAGNOSTICS"
    private static let envLogPathKey = "OPENASSIST_INSERTION_DIAGNOSTICS_PATH"
    private static let defaultLogPath = "/tmp/openassist-insertion-diagnostics.log"
    private static let writeQueue = DispatchQueue(label: "OpenAssist.InsertionDiagnostics")

    static var isEnabled: Bool {
        if let envValue = ProcessInfo.processInfo.environment[envEnabledKey],
           let parsed = parseBool(envValue) {
            return parsed
        }

        return UserDefaults.standard.bool(forKey: defaultsEnabledKey)
    }

    static var logPath: String {
        let path = ProcessInfo.processInfo.environment[envLogPathKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let path, !path.isEmpty {
            return path
        }
        return defaultLogPath
    }

    static func record(decision: InsertionDecision, text: String, copyToClipboard: Bool) {
        guard isEnabled else { return }

        let payload: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "path": decision.path.rawValue,
            "result": decision.result.rawValue,
            "copyToClipboard": copyToClipboard,
            "textLength": text.count
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8)
        else {
            return
        }

        appendLine(line)
    }

    private static func appendLine(_ line: String) {
        writeQueue.async {
            let url = URL(fileURLWithPath: logPath)
            let lineData = Data((line + "\n").utf8)

            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                _ = try? handle.write(contentsOf: lineData)
                return
            }

            try? lineData.write(to: url, options: .atomic)
        }
    }

    private static func parseBool(_ value: String) -> Bool? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }
}
