import AppKit
import Foundation
import OSLog

/// Top-level C function pointer for signal handling (cannot capture context).
private func crashSignalHandler(_ signalNumber: Int32) {
    let info = """
    === OpenAssist Signal Crash ===
    Date: \(ISO8601DateFormatter().string(from: Date()))
    Signal: \(signalNumber)
    ===
    """
    CrashReporter.appendToLog(info)
    // Re-raise so the default handler runs
    signal(signalNumber, SIG_DFL)
    raise(signalNumber)
}

/// Lightweight, local-only crash and error reporter.
/// Writes logs to ~/Library/Logs/OpenAssist/ — no network calls.
enum CrashReporter {
    private static let logger = Logger(subsystem: "OpenAssist", category: "CrashReporter")
    private static let logDirectoryName = "OpenAssist"
    private static let crashLogName = "crash.log"
    private static let maxLogSizeBytes = 512 * 1024 // 512 KB
    private static let defaultDiagnosticLogSizeBytes = 2 * 1024 * 1024 // 2 MB

    /// Install signal and exception handlers. Call once at app launch.
    static func install() {
        NSSetUncaughtExceptionHandler { exception in
            let info = """
            === OpenAssist Crash ===
            Date: \(ISO8601DateFormatter().string(from: Date()))
            Name: \(exception.name.rawValue)
            Reason: \(exception.reason ?? "unknown")
            Stack:
            \(exception.callStackSymbols.joined(separator: "\n"))
            ===
            """
            CrashReporter.appendToLog(info)
        }

        // Catch common fatal signals
        for sig: Int32 in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE] {
            signal(sig, crashSignalHandler)
        }

        logger.info("CrashReporter installed")
    }


    /// Log a non-fatal informational event for diagnostics.
    static func logInfo(_ message: String, file: String = #file, line: Int = #line) {
        appendStructuredLog(level: "INFO", message: message, file: file, line: line)
    }

    /// Log a non-fatal warning for diagnostics.
    static func logWarning(_ message: String, file: String = #file, line: Int = #line) {
        appendStructuredLog(level: "WARN", message: message, file: file, line: line)
    }

    /// Log a non-fatal error for diagnostics.
    static func logError(_ message: String, file: String = #file, line: Int = #line) {
        appendStructuredLog(level: "ERROR", message: message, file: file, line: line)
    }

    /// Returns the crash log URL, or nil if no logs exist.
    static var logFileURL: URL? {
        let url = logDirectory.appendingPathComponent(crashLogName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Returns true if crash logs exist on disk.
    static var hasLogs: Bool {
        logFileURL != nil
    }

    /// Reveals the crash log in Finder.
    static func revealInFinder() {
        guard let url = logFileURL else { return }
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
    }

    /// Returns the URL for a diagnostic log file inside the OpenAssist log directory.
    static func diagnosticLogURL(named fileName: String) -> URL {
        logDirectory.appendingPathComponent(fileName)
    }

    /// Appends test-oriented diagnostics to a named log file.
    static func appendDiagnosticLog(
        _ text: String,
        fileName: String,
        maxSizeBytes: Int = defaultDiagnosticLogSizeBytes
    ) {
        append(text, fileName: fileName, maxSizeBytes: maxSizeBytes)
    }

    // MARK: - Private

    private static var logDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Logs/\(logDirectoryName)")
    }

    fileprivate static func appendToLog(_ text: String) {
        append(text, fileName: crashLogName, maxSizeBytes: maxLogSizeBytes)
    }

    private static func append(_ text: String, fileName: String, maxSizeBytes: Int) {
        let dir = logDirectory
        let fileURL = dir.appendingPathComponent(fileName)

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            // Best effort — can't log if we can't create the directory
            return
        }

        let line = text + "\n"

        if FileManager.default.fileExists(atPath: fileURL.path) {
            // Truncate if too large
            if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
               let size = attrs[.size] as? Int,
               size > maxSizeBytes {
                // Keep last half of the log
                if let data = try? Data(contentsOf: fileURL) {
                    let halfIndex = data.count / 2
                    let trimmed = data.suffix(from: halfIndex)
                    try? trimmed.write(to: fileURL)
                }
            }

            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                handle.write(Data(line.utf8))
            }
        } else {
            try? Data(line.utf8).write(to: fileURL, options: .atomic)
        }
    }

    private static func appendStructuredLog(level: String, message: String, file: String, line: Int) {
        let entry = """
        [\(level)] \(ISO8601DateFormatter().string(from: Date())) \(URL(fileURLWithPath: file).lastPathComponent):\(line) \(message)
        """
        appendToLog(entry)
    }
}
