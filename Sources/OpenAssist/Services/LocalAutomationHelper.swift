import AppKit
import Carbon
import CoreGraphics
import CoreServices
import Foundation

struct LocalAutomationDisplaySnapshot {
    let image: CGImage
    let imageSize: CGSize
    let screenFrame: CGRect
    let imageDataURL: String
}

enum LocalAutomationError: LocalizedError {
    case accessibilityRequired
    case screenRecordingRequired
    case appleEventsPermissionRequired
    case browserProfileUnavailable
    case browserAutomationDisabled
    case unsupportedAction(String)
    case invalidArguments(String)
    case pathNotFound(String)
    case scriptFailed(String)
    case commandFailed(String)
    case calendarDateInvalid
    case screenshotFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityRequired:
            return "Accessibility permission is required so Open Assist can click and type."
        case .screenRecordingRequired:
            return "Screen Recording permission is required so Open Assist can see the current screen."
        case .appleEventsPermissionRequired:
            return "Automation permission is required so Open Assist can control Mac apps directly."
        case .browserProfileUnavailable:
            return "The selected browser profile is unavailable. Choose a browser profile in Computer Control settings."
        case .browserAutomationDisabled:
            return "Browser automation is off. Turn it on in Computer Control settings first."
        case .unsupportedAction(let message):
            return message
        case .invalidArguments(let message):
            return message
        case .pathNotFound(let path):
            return "The path does not exist: \(path)"
        case .scriptFailed(let message):
            return message
        case .commandFailed(let message):
            return message
        case .calendarDateInvalid:
            return "Calendar actions need valid ISO 8601 start and end dates."
        case .screenshotFailed:
            return "Open Assist could not capture the current screen."
        }
    }
}

actor LocalAutomationHelper {
    static let shared = LocalAutomationHelper()

    private let iso8601Formatter = ISO8601DateFormatter()

    func capabilityStatus(
        selectedBrowserProfile: BrowserProfile?,
        settings: SettingsStore
    ) async -> HelperCapabilityStatus {
        let snapshot = await MainActor.run { PermissionCenter.snapshot(using: settings) }
        var issues: [String] = []
        if !snapshot.accessibilityGranted {
            issues.append("Accessibility is still needed for computer control.")
        }
        if !snapshot.screenRecordingGranted {
            issues.append("Screen Recording is still needed for live screen understanding.")
        }
        if snapshot.appleEventsKnown && !snapshot.appleEventsGranted {
            issues.append("Automation permission is still needed for browser and app scripting.")
        }
        if selectedBrowserProfile == nil {
            issues.append("Choose a browser profile to reuse signed-in browser sessions.")
        }

        return HelperCapabilityStatus(
            helperName: "Local Automation Helper",
            available: true,
            executionMode: "In-process helper",
            permissions: LocalAutomationPermissionSnapshot(
                accessibilityGranted: snapshot.accessibilityGranted,
                screenRecordingGranted: snapshot.screenRecordingGranted,
                appleEventsGranted: snapshot.appleEventsGranted,
                appleEventsKnown: snapshot.appleEventsKnown,
                fullDiskAccessGranted: snapshot.fullDiskAccessGranted,
                fullDiskAccessKnown: snapshot.fullDiskAccessKnown
            ),
            connectors: Self.defaultConnectors,
            supportedBrowsers: SupportedBrowser.allCases.map(\.displayName),
            selectedBrowserProfileLabel: selectedBrowserProfile?.label,
            issues: issues
        )
    }

    func executeComputerActions(
        _ actions: [[String: Any]],
        previousSnapshot: LocalAutomationDisplaySnapshot?
    ) async throws -> LocalAutomationDisplaySnapshot {
        guard AXIsProcessTrusted() else {
            throw LocalAutomationError.accessibilityRequired
        }
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            throw LocalAutomationError.screenRecordingRequired
        }

        let initialSnapshot: LocalAutomationDisplaySnapshot
        if let previousSnapshot {
            initialSnapshot = previousSnapshot
        } else {
            initialSnapshot = try captureSnapshot()
        }
        var coordinateSnapshot = initialSnapshot
        for action in actions {
            let type = (action["type"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""

            switch type {
            case "screenshot":
                coordinateSnapshot = try captureSnapshot()
            case "click":
                let point = try screenPoint(from: action, snapshot: coordinateSnapshot)
                try await click(at: point, button: button(from: action["button"] as? String), clickCount: 1)
            case "double_click":
                let point = try screenPoint(from: action, snapshot: coordinateSnapshot)
                try await click(at: point, button: .left, clickCount: 2)
            case "move":
                let point = try screenPoint(from: action, snapshot: coordinateSnapshot)
                try moveMouse(to: point)
            case "drag":
                let path = try dragPath(from: action, snapshot: coordinateSnapshot)
                try await drag(along: path)
            case "scroll":
                let point = try screenPoint(from: action, snapshot: coordinateSnapshot)
                let scrollX = number(from: action["scroll_x"]) ?? 0
                let scrollY = number(from: action["scroll_y"]) ?? 0
                try await scroll(at: point, deltaX: scrollX, deltaY: scrollY)
            case "keypress":
                let keys = (action["keys"] as? [Any])?.compactMap { value -> String? in
                    (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                } ?? []
                try await keypress(keys)
            case "type":
                try await typeText((action["text"] as? String) ?? "")
            case "wait":
                try await pause(for: 1.0)
            default:
                continue
            }

            try await pause(for: 0.18)
        }

        return try captureSnapshot()
    }

    func activateBrowser(_ browser: SupportedBrowser) async throws {
        let script = """
        tell application "\(browser.displayName)"
            activate
        end tell
        """
        _ = try await runAppleScript(script)
    }

    func openBrowserURL(_ url: URL, profile: BrowserProfile) async throws {
        let applicationPath: String
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: profile.browser.bundleIdentifier) {
            applicationPath = appURL.path
        } else if FileManager.default.fileExists(atPath: profile.browser.appPath) {
            applicationPath = profile.browser.appPath
        } else {
            throw LocalAutomationError.browserProfileUnavailable
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = Self.browserOpenCommandArguments(
            appPath: applicationPath,
            profile: profile,
            url: url
        )
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw LocalAutomationError.commandFailed("Could not launch \(profile.browser.displayName) with the selected profile.")
        }
    }

    func readFrontBrowserTab(browser: SupportedBrowser) async throws -> (title: String?, url: String?) {
        let script = """
        tell application "\(browser.displayName)"
            if not running then error "Browser is not running."
            set tabTitle to title of active tab of front window
            set tabURL to URL of active tab of front window
            return tabTitle & linefeed & tabURL
        end tell
        """

        let output = try await runAppleScript(script)
        let lines = output.components(separatedBy: .newlines).filter { !$0.isEmpty }
        return (lines.first, lines.dropFirst().first)
    }

    func revealInFinder(path: String) throws {
        let expandedPath = NSString(string: path).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LocalAutomationError.pathNotFound(expandedPath)
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openInFinder(path: String) throws {
        let expandedPath = NSString(string: path).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LocalAutomationError.pathNotFound(expandedPath)
        }
        NSWorkspace.shared.open(url)
    }

    func runTerminalCommand(_ command: String) async throws {
        let escaped = Self.appleScriptEscaped(command)
        let script = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        _ = try await runAppleScript(script)
    }

    func openSystemSettings(pane: String?) async {
        let trimmed = pane?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let fallbackURL = URL(fileURLWithPath: "/System/Applications/System Settings.app")
        let targetURL = Self.systemSettingsURL(for: trimmed) ?? fallbackURL
        await MainActor.run {
            _ = NSWorkspace.shared.open(targetURL)
        }
    }

    static func browserOpenCommandArguments(
        appPath: String,
        profile: BrowserProfile,
        url: URL
    ) -> [String] {
        [
            "-na",
            appPath,
            "--args",
            "--profile-directory=\(profile.directoryName)",
            url.absoluteString
        ]
    }

    static func systemSettingsURL(for pane: String?) -> URL? {
        let trimmed = pane?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            return URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension")
        }

        if let privacyQuery = normalizedPrivacyQuery(for: trimmed) {
            return PermissionCenter.privacySettingsURLs(query: privacyQuery).first
        }

        let normalized = trimmed.lowercased()
        if let paneIdentifier = Self.systemSettingsPaneIdentifiers[normalized] {
            return URL(string: "x-apple.systempreferences:\(paneIdentifier)")
        }

        return nil
    }

    func previewCalendarEvent(
        title: String,
        startISO8601: String,
        endISO8601: String,
        notes: String?
    ) throws -> String {
        let start = try calendarDate(from: startISO8601)
        let end = try calendarDate(from: endISO8601)
        return """
        Title: \(title)
        Start: \(Self.humanDateFormatter.string(from: start))
        End: \(Self.humanDateFormatter.string(from: end))
        Notes: \((notes?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty) ?? "None")
        """
    }

    func createCalendarEvent(
        title: String,
        startISO8601: String,
        endISO8601: String,
        notes: String?
    ) async throws {
        let start = try calendarDate(from: startISO8601)
        let end = try calendarDate(from: endISO8601)
        let escapedTitle = Self.appleScriptEscaped(title)
        let escapedNotes = Self.appleScriptEscaped(notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        let script = """
        tell application "Calendar"
            activate
            set targetCalendar to first calendar
            tell targetCalendar
                make new event with properties {summary:"\(escapedTitle)", start date:date "\(Self.appleScriptDateFormatter.string(from: start))", end date:date "\(Self.appleScriptDateFormatter.string(from: end))", description:"\(escapedNotes)"}
            end tell
        end tell
        """
        _ = try await runAppleScript(script)
    }

    func runAppleScript(_ script: String) async throws -> String {
        // Run in-process via NSAppleScript so macOS attributes the Automation
        // permission to Open Assist itself (persisted in TCC) instead of to a
        // transient osascript child process that re-prompts every time.
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var errorDict: NSDictionary?
                let appleScript = NSAppleScript(source: script)
                let result = appleScript?.executeAndReturnError(&errorDict)

                if let errorDict {
                    let errorNumber = errorDict[NSAppleScript.errorNumber] as? Int ?? 0
                    let errorMessage = errorDict[NSAppleScript.errorMessage] as? String ?? "AppleScript failed."
                    if errorNumber == -1743 || errorMessage.localizedCaseInsensitiveContains("Not authorized to send Apple events") {
                        continuation.resume(throwing: LocalAutomationError.appleEventsPermissionRequired)
                    } else {
                        continuation.resume(throwing: LocalAutomationError.scriptFailed(errorMessage))
                    }
                    return
                }

                let output = result?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                continuation.resume(returning: output)
            }
        }
    }

    private func captureSnapshot() throws -> LocalAutomationDisplaySnapshot {
        guard let screen = Self.activeScreen() else {
            throw LocalAutomationError.screenshotFailed
        }
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw LocalAutomationError.screenshotFailed
        }

        let displayID = CGDirectDisplayID(screenNumber.uint32Value)
        guard let image = CGDisplayCreateImage(displayID) else {
            throw LocalAutomationError.screenshotFailed
        }

        let imageSize = CGSize(width: image.width, height: image.height)
        let imageDataURL = try Self.pngDataURL(for: image)
        return LocalAutomationDisplaySnapshot(
            image: image,
            imageSize: imageSize,
            screenFrame: screen.frame,
            imageDataURL: imageDataURL
        )
    }

    private static func activeScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func screenPoint(
        from action: [String: Any],
        snapshot: LocalAutomationDisplaySnapshot
    ) throws -> CGPoint {
        let x = number(from: action["x"])
        let y = number(from: action["y"])
        guard let x, let y else {
            throw LocalAutomationError.invalidArguments("Computer control needs screen coordinates.")
        }

        let scaleX = snapshot.imageSize.width / max(1, snapshot.screenFrame.width)
        let scaleY = snapshot.imageSize.height / max(1, snapshot.screenFrame.height)
        let screenX = snapshot.screenFrame.minX + CGFloat(x) / max(1, scaleX)
        let screenY = snapshot.screenFrame.maxY - CGFloat(y) / max(1, scaleY)
        return CGPoint(
            x: min(max(screenX, snapshot.screenFrame.minX + 1), snapshot.screenFrame.maxX - 1),
            y: min(max(screenY, snapshot.screenFrame.minY + 1), snapshot.screenFrame.maxY - 1)
        )
    }

    private func dragPath(
        from action: [String: Any],
        snapshot: LocalAutomationDisplaySnapshot
    ) throws -> [CGPoint] {
        guard let path = action["path"] as? [[String: Any]], !path.isEmpty else {
            throw LocalAutomationError.invalidArguments("Computer control needs a drag path.")
        }
        return try path.map { point in
            try screenPoint(from: point, snapshot: snapshot)
        }
    }

    private func button(from rawValue: String?) -> CGMouseButton {
        switch rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "right":
            return .right
        default:
            return .left
        }
    }

    private func click(at point: CGPoint, button: CGMouseButton, clickCount: Int) async throws {
        let source = try eventSource()
        let moved = mouseEvent(source: source, type: .mouseMoved, point: point, button: .left)
        moved.post(tap: .cgSessionEventTap)

        let downType: CGEventType = button == .right ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = button == .right ? .rightMouseUp : .leftMouseUp

        for index in 1...clickCount {
            let down = mouseEvent(source: source, type: downType, point: point, button: button)
            let up = mouseEvent(source: source, type: upType, point: point, button: button)
            down.setIntegerValueField(.mouseEventClickState, value: Int64(index))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(index))
            down.post(tap: .cgSessionEventTap)
            up.post(tap: .cgSessionEventTap)
            try await pause(for: 0.05)
        }
    }

    private func moveMouse(to point: CGPoint) throws {
        let source = try eventSource()
        let moved = mouseEvent(source: source, type: .mouseMoved, point: point, button: .left)
        moved.post(tap: .cgSessionEventTap)
    }

    private func drag(along path: [CGPoint]) async throws {
        guard let first = path.first else { return }
        let source = try eventSource()

        let moved = mouseEvent(source: source, type: .mouseMoved, point: first, button: .left)
        moved.post(tap: .cgSessionEventTap)
        try await pause(for: 0.04)

        let down = mouseEvent(source: source, type: .leftMouseDown, point: first, button: .left)
        down.post(tap: .cgSessionEventTap)
        try await pause(for: 0.04)

        for point in path.dropFirst() {
            let dragged = mouseEvent(source: source, type: .leftMouseDragged, point: point, button: .left)
            dragged.post(tap: .cgSessionEventTap)
            try await pause(for: 0.03)
        }

        if let last = path.last {
            let up = mouseEvent(source: source, type: .leftMouseUp, point: last, button: .left)
            up.post(tap: .cgSessionEventTap)
        }
    }

    private func scroll(at point: CGPoint, deltaX: Double, deltaY: Double) async throws {
        let source = try eventSource()
        let moved = mouseEvent(source: source, type: .mouseMoved, point: point, button: .left)
        moved.post(tap: .cgSessionEventTap)
        try await pause(for: 0.03)

        guard let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32((-deltaY).rounded()),
            wheel2: Int32(deltaX.rounded()),
            wheel3: 0
        ) else {
            throw LocalAutomationError.commandFailed("Computer control could not create a scroll event.")
        }
        event.location = point
        event.post(tap: .cgSessionEventTap)
    }

    private func keypress(_ keys: [String]) async throws {
        guard !keys.isEmpty else { return }
        let source = try eventSource()

        var modifiers: CGEventFlags = []
        var primaryKeys: [String] = []

        for rawKey in keys {
            let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch key {
            case "cmd", "command", "meta", "super":
                modifiers.insert(.maskCommand)
            case "ctrl", "control":
                modifiers.insert(.maskControl)
            case "alt", "option":
                modifiers.insert(.maskAlternate)
            case "shift":
                modifiers.insert(.maskShift)
            default:
                primaryKeys.append(key)
            }
        }

        if primaryKeys.isEmpty {
            primaryKeys = ["tab"]
        }

        for key in primaryKeys {
            if let keyCode = Self.keyCodeMap[key] {
                guard
                    let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
                    let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
                else {
                    throw LocalAutomationError.commandFailed("Computer control could not create a key event.")
                }
                down.flags = modifiers
                up.flags = modifiers
                down.post(tap: .cgSessionEventTap)
                up.post(tap: .cgSessionEventTap)
            } else if modifiers.isEmpty {
                try await typeText(key)
            }
            try await pause(for: 0.03)
        }
    }

    private func typeText(_ text: String) async throws {
        let source = try eventSource()
        for scalar in text.unicodeScalars {
            if scalar.value == 10 {
                guard
                    let down = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true),
                    let up = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false)
                else {
                    throw LocalAutomationError.commandFailed("Computer control could not create a return key event.")
                }
                down.post(tap: .cgSessionEventTap)
                up.post(tap: .cgSessionEventTap)
                continue
            }

            var units = Array(String(scalar).utf16)
            guard
                let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else {
                throw LocalAutomationError.commandFailed("Computer control could not create a typing event.")
            }
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            down.post(tap: .cgSessionEventTap)
            up.post(tap: .cgSessionEventTap)
            try await pause(for: 0.01)
        }
    }

    private func mouseEvent(
        source: CGEventSource,
        type: CGEventType,
        point: CGPoint,
        button: CGMouseButton
    ) -> CGEvent {
        CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)!
    }

    private func eventSource() throws -> CGEventSource {
        guard let source = CGEventSource(stateID: .combinedSessionState)
            ?? CGEventSource(stateID: .hidSystemState) else {
            throw LocalAutomationError.commandFailed("Computer control could not access the macOS event source.")
        }
        return source
    }

    private func pause(for seconds: TimeInterval) async throws {
        let nanoseconds = UInt64((seconds * 1_000_000_000).rounded())
        try await Task.sleep(nanoseconds: nanoseconds)
    }

    private func number(from raw: Any?) -> Double? {
        if let number = raw as? NSNumber {
            return number.doubleValue
        }
        if let text = raw as? String {
            return Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private func calendarDate(from text: String) throws -> Date {
        guard let date = iso8601Formatter.date(from: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw LocalAutomationError.calendarDateInvalid
        }
        return date
    }

    private static func pngDataURL(for image: CGImage) throws -> String {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            throw LocalAutomationError.screenshotFailed
        }
        return "data:image/png;base64,\(pngData.base64EncodedString())"
    }

    private static func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func normalizedPrivacyQuery(for pane: String) -> String? {
        if pane.hasPrefix("Privacy_") {
            return pane
        }

        let normalized = pane.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "screen recording", "screen capture":
            return "Privacy_ScreenCapture"
        case "automation", "apple events":
            return "Privacy_Automation"
        case "microphone":
            return "Privacy_Microphone"
        case "speech recognition", "speech":
            return "Privacy_SpeechRecognition"
        case "full disk access", "all files":
            return "Privacy_AllFiles"
        default:
            return normalized.contains("privacy") ? pane : nil
        }
    }

    private static let humanDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let appleScriptDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm:ss a"
        return formatter
    }()

    private static let defaultConnectors: [ConnectorDescriptor] = [
        ConnectorDescriptor(
            id: "computer",
            displayName: "Computer Use",
            summary: "Fallback live screen control for clicking, typing, and reading visible UI.",
            kind: .computer,
            supportedActions: ["click", "type", "scroll", "read screen"]
        ),
        ConnectorDescriptor(
            id: "browser",
            displayName: "Browser Use",
            summary: "Direct browser actions using your selected signed-in browser profile.",
            kind: .browser,
            supportedActions: ["open URL", "read current tab", "activate browser"]
        ),
        ConnectorDescriptor(
            id: "finder",
            displayName: "Finder",
            summary: "Reveal or open files and folders directly.",
            kind: .app,
            supportedActions: ["reveal", "open"]
        ),
        ConnectorDescriptor(
            id: "terminal",
            displayName: "Terminal",
            summary: "Open Terminal and run a command directly.",
            kind: .app,
            supportedActions: ["run command"]
        ),
        ConnectorDescriptor(
            id: "calendar",
            displayName: "Calendar",
            summary: "Preview and create calendar events.",
            kind: .app,
            supportedActions: ["preview event", "create event"]
        ),
        ConnectorDescriptor(
            id: "system-settings",
            displayName: "System Settings",
            summary: "Open the requested settings pane directly.",
            kind: .app,
            supportedActions: ["open pane"]
        )
    ]

    private static let keyCodeMap: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
        "tab": 48, "space": 49, "`": 50, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "command": 55, "shift": 56, "capslock": 57, "option": 58, "control": 59,
        "return": 36, "enter": 36,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "pageup": 116, "pagedown": 121, "home": 115, "end": 119, "forwarddelete": 117
    ]

    private static let systemSettingsPaneIdentifiers: [String: String] = [
        "appearance": "com.apple.Appearance-Settings.extension",
        "battery": "com.apple.Battery-Settings.extension*BatteryPreferences",
        "bluetooth": "com.apple.BluetoothSettings",
        "date & time": "com.apple.Date-Time-Settings.extension",
        "date and time": "com.apple.Date-Time-Settings.extension",
        "desktop & dock": "com.apple.Desktop-Settings.extension",
        "desktop and dock": "com.apple.Desktop-Settings.extension",
        "displays": "com.apple.Displays-Settings.extension",
        "display": "com.apple.Displays-Settings.extension",
        "family": "com.apple.Family-Settings.extension*Family",
        "general": "com.apple.Appearance-Settings.extension",
        "internet accounts": "com.apple.Internet-Accounts-Settings.extension",
        "keyboard": "com.apple.Keyboard-Settings.extension",
        "mouse": "com.apple.Mouse-Settings.extension",
        "network": "com.apple.Network-Settings.extension",
        "notifications": "com.apple.Notifications-Settings.extension",
        "passwords": "com.apple.Passwords-Settings.extension",
        "profiles": "com.apple.Profiles-Settings.extension",
        "screen time": "com.apple.Screen-Time-Settings.extension",
        "sharing": "com.apple.Sharing-Settings.extension",
        "software update": "com.apple.Software-Update-Settings.extension",
        "sound": "com.apple.Sound-Settings.extension",
        "startup disk": "com.apple.Startup-Disk-Settings.extension",
        "time machine": "com.apple.Time-Machine-Settings.extension",
        "trackpad": "com.apple.Trackpad-Settings.extension",
        "users & groups": "com.apple.Users-Groups-Settings.extension",
        "users and groups": "com.apple.Users-Groups-Settings.extension",
        "wallet": "com.apple.WalletSettingsExtension",
        "wallpaper": "com.apple.Wallpaper-Settings.extension",
        "wi-fi": "com.apple.Network-Settings.extension",
        "wifi": "com.apple.Network-Settings.extension"
    ]
}
