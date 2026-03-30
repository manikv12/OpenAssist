import AppKit
import CoreGraphics
import Foundation

enum AssistantViewImageToolDefinition {
    static let name = "view_image"
    static let toolKind = "imageInspection"

    static let description = """
    Load a local image file from this Mac and return it to the conversation for visual inspection.
    """

    static let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "path": [
                "type": "string",
                "description": "Absolute local file path to an image."
            ]
        ],
        "required": ["path"],
        "additionalProperties": true
    ]
}

enum AssistantScreenCaptureToolDefinition {
    static let name = "screen_capture"
    static let toolKind = "screenCapture"

    static let description = """
    Capture the active display on this Mac and return the screenshot to the conversation.
    """

    static let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "display": [
                "type": "string",
                "description": "Optional display hint."
            ],
            "display_id": [
                "type": "integer",
                "description": "Optional exact display id."
            ],
            "window_id": [
                "type": "integer",
                "description": "Optional exact window id to capture instead of a whole display."
            ],
            "frontmost": [
                "type": "boolean",
                "description": "When true, capture the frontmost visible window instead of the active display."
            ]
        ],
        "additionalProperties": true
    ]
}

enum AssistantWindowListToolDefinition {
    static let name = "window_list"
    static let toolKind = "windowInspection"

    static let description = """
    List the currently visible windows on this Mac, including their ids, owning apps, titles, and bounds.
    """

    static let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "app": [
                "type": "string",
                "description": "Optional app name filter."
            ],
            "title": [
                "type": "string",
                "description": "Optional window title filter."
            ],
            "top": [
                "type": "integer",
                "description": "Maximum number of windows to return."
            ]
        ],
        "additionalProperties": true
    ]
}

enum AssistantWindowCaptureToolDefinition {
    static let name = "window_capture"
    static let toolKind = "windowCapture"

    static let description = """
    Capture one visible app window on this Mac by window id, app name, or title and return the screenshot to the conversation.
    """

    static let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "window_id": [
                "type": "integer",
                "description": "Optional exact window id."
            ],
            "app": [
                "type": "string",
                "description": "Optional app name filter."
            ],
            "title": [
                "type": "string",
                "description": "Optional window title filter."
            ]
        ],
        "additionalProperties": true
    ]
}

enum AssistantWindowAutomationServiceError: LocalizedError {
    case invalidArguments(String)
    case fileNotFound(String)
    case invalidImagePath
    case screenRecordingRequired
    case captureFailed
    case windowNotFound

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let message),
             .fileNotFound(let message):
            return message
        case .invalidImagePath:
            return "Open Assist needs a valid local image path."
        case .screenRecordingRequired:
            return "Grant Screen Recording so Open Assist can capture the screen or windows."
        case .captureFailed:
            return "Open Assist could not capture the requested screen or window."
        case .windowNotFound:
            return "Open Assist could not find a visible window matching that request."
        }
    }
}

actor AssistantWindowAutomationService {
    struct ViewImageRequest: Equatable, Sendable {
        let path: String

        var summaryLine: String {
            "Load \(URL(fileURLWithPath: path).lastPathComponent)"
        }
    }

    struct ScreenCaptureRequest: Equatable, Sendable {
        let displayHint: String?
        let displayID: Int?
        let windowID: Int?
        let frontmost: Bool

        var summaryLine: String {
            if let windowID {
                return "Capture window \(windowID)"
            }
            if frontmost {
                return "Capture the frontmost window"
            }
            if let displayID {
                return "Capture display \(displayID)"
            }
            return "Capture the active display"
        }
    }

    struct WindowListRequest: Equatable, Sendable {
        let appName: String?
        let title: String?
        let top: Int

        var summaryLine: String {
            if let appName = appName?.nonEmpty {
                return "List visible windows for \(appName)"
            }
            return "List visible windows"
        }
    }

    struct WindowCaptureRequest: Equatable, Sendable {
        let windowID: Int?
        let appName: String?
        let title: String?

        var summaryLine: String {
            if let windowID {
                return "Capture window \(windowID)"
            }
            if let appName = appName?.nonEmpty {
                return "Capture a visible \(appName) window"
            }
            return "Capture a visible window"
        }
    }

    struct WindowInfo: Equatable, Sendable {
        let windowID: Int
        let ownerName: String
        let ownerPID: pid_t
        let title: String
        let bounds: CGRect
        let layer: Int
        let alpha: Double
        let displayID: CGDirectDisplayID?
    }

    static func parseViewImageRequest(from arguments: Any) throws -> ViewImageRequest {
        guard let dictionary = normalizedDictionary(from: arguments),
              let path = (dictionary["path"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty else {
            throw AssistantWindowAutomationServiceError.invalidArguments("view_image needs a local `path`.")
        }
        return ViewImageRequest(path: path)
    }

    static func parseScreenCaptureRequest(from arguments: Any) throws -> ScreenCaptureRequest {
        let dictionary = normalizedDictionary(from: arguments) ?? [:]
        return ScreenCaptureRequest(
            displayHint: (dictionary["display"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty,
            displayID: integer(from: dictionary["display_id"]),
            windowID: integer(from: dictionary["window_id"]),
            frontmost: boolean(from: dictionary["frontmost"]) ?? false
        )
    }

    static func parseWindowListRequest(from arguments: Any) throws -> WindowListRequest {
        let dictionary = normalizedDictionary(from: arguments) ?? [:]
        let top = min(max(integer(from: dictionary["top"]) ?? 20, 1), 100)
        return WindowListRequest(
            appName: (dictionary["app"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty,
            title: (dictionary["title"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty,
            top: top
        )
    }

    static func parseWindowCaptureRequest(from arguments: Any) throws -> WindowCaptureRequest {
        let dictionary = normalizedDictionary(from: arguments) ?? [:]
        return WindowCaptureRequest(
            windowID: integer(from: dictionary["window_id"]),
            appName: (dictionary["app"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty,
            title: (dictionary["title"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty
        )
    }

    func viewImage(
        arguments: Any,
        preferredModelID: String?
    ) async -> AssistantToolExecutionResult {
        _ = preferredModelID
        do {
            let request = try Self.parseViewImageRequest(from: arguments)
            let expandedPath = NSString(string: request.path).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expandedPath) else {
                throw AssistantWindowAutomationServiceError.fileNotFound("Open Assist could not find the image at \(expandedPath).")
            }
            guard let image = NSImage(contentsOfFile: expandedPath),
                  let dataURL = try Self.dataURL(for: image) else {
                throw AssistantWindowAutomationServiceError.invalidImagePath
            }
            let message = "Loaded image: \(URL(fileURLWithPath: expandedPath).lastPathComponent)"
            return AssistantToolExecutionResult(
                contentItems: [
                    .init(type: "inputText", text: message, imageURL: nil),
                    .init(type: "inputImage", text: nil, imageURL: dataURL)
                ],
                success: true,
                summary: message
            )
        } catch {
            let message = error.localizedDescription
            return AssistantToolExecutionResult(
                contentItems: [.init(type: "inputText", text: message, imageURL: nil)],
                success: false,
                summary: message
            )
        }
    }

    func captureScreen(
        arguments: Any,
        preferredModelID: String?
    ) async -> AssistantToolExecutionResult {
        _ = preferredModelID
        do {
            let request = try Self.parseScreenCaptureRequest(from: arguments)
            guard CGPreflightScreenCaptureAccess() else {
                throw AssistantWindowAutomationServiceError.screenRecordingRequired
            }

            if request.frontmost || request.windowID != nil {
                guard let window = Self.resolveWindow(
                    windowID: request.windowID,
                    appName: nil,
                    title: nil,
                    preferFrontmost: true
                ), let image = Self.captureWindowImage(for: window) else {
                    throw AssistantWindowAutomationServiceError.windowNotFound
                }
                let dataURL = try Self.pngDataURL(for: image)
                let title = window.title.isEmpty ? "(untitled)" : window.title
                let message = "Captured window \(window.windowID) from \(window.ownerName): \(title)"
                return AssistantToolExecutionResult(
                    contentItems: [
                        .init(type: "inputText", text: message, imageURL: nil),
                        .init(type: "inputImage", text: nil, imageURL: dataURL)
                    ],
                    success: true,
                    summary: message
                )
            }

            if let displayID = request.displayID {
                guard let image = Self.captureDisplayImage(displayID: CGDirectDisplayID(displayID)) else {
                    throw AssistantWindowAutomationServiceError.captureFailed
                }
                let dataURL = try Self.pngDataURL(for: image)
                let message = "Captured display \(displayID)."
                return AssistantToolExecutionResult(
                    contentItems: [
                        .init(type: "inputText", text: message, imageURL: nil),
                        .init(type: "inputImage", text: nil, imageURL: dataURL)
                    ],
                    success: true,
                    summary: message
                )
            }

            guard let active = Self.activeDisplayInfo(),
                  let image = Self.captureDisplayImage(displayID: active.displayID) else {
                throw AssistantWindowAutomationServiceError.captureFailed
            }
            let dataURL = try Self.pngDataURL(for: image)
            let message = "Captured the active display."
            return AssistantToolExecutionResult(
                contentItems: [
                    .init(type: "inputText", text: message, imageURL: nil),
                    .init(type: "inputImage", text: nil, imageURL: dataURL)
                ],
                success: true,
                summary: message
            )
        } catch {
            let message = error.localizedDescription
            return AssistantToolExecutionResult(
                contentItems: [.init(type: "inputText", text: message, imageURL: nil)],
                success: false,
                summary: message
            )
        }
    }

    func listWindows(
        arguments: Any,
        preferredModelID: String?
    ) async -> AssistantToolExecutionResult {
        _ = preferredModelID
        do {
            let request = try Self.parseWindowListRequest(from: arguments)
            let windows = Self.visibleWindows()
                .filter { window in
                    if let appName = request.appName?.lowercased(),
                       !window.ownerName.lowercased().contains(appName) {
                        return false
                    }
                    if let title = request.title?.lowercased(),
                       !window.title.lowercased().contains(title) {
                        return false
                    }
                    return true
                }
            let lines = windows.prefix(request.top).map { window in
                let bounds = "x=\(Int(window.bounds.origin.x)) y=\(Int(window.bounds.origin.y)) w=\(Int(window.bounds.width)) h=\(Int(window.bounds.height))"
                let title = window.title.isEmpty ? "(untitled)" : window.title
                return "\(window.windowID)\t\(window.ownerName)\t\(title)\t\(bounds)"
            }
            let message: String
            if lines.isEmpty {
                message = "No visible windows matched that filter."
            } else {
                message = (["Visible windows:"] + lines).joined(separator: "\n")
            }
            return AssistantToolExecutionResult(
                contentItems: [.init(type: "inputText", text: message, imageURL: nil)],
                success: true,
                summary: lines.isEmpty ? "No visible windows matched." : "Listed visible windows."
            )
        } catch {
            let message = error.localizedDescription
            return AssistantToolExecutionResult(
                contentItems: [.init(type: "inputText", text: message, imageURL: nil)],
                success: false,
                summary: message
            )
        }
    }

    func captureWindow(
        arguments: Any,
        preferredModelID: String?
    ) async -> AssistantToolExecutionResult {
        _ = preferredModelID
        do {
            let request = try Self.parseWindowCaptureRequest(from: arguments)
            guard CGPreflightScreenCaptureAccess() else {
                throw AssistantWindowAutomationServiceError.screenRecordingRequired
            }

            guard let window = Self.resolveWindow(request: request) else {
                throw AssistantWindowAutomationServiceError.windowNotFound
            }
            guard let image = Self.captureWindowImage(for: window) else {
                throw AssistantWindowAutomationServiceError.captureFailed
            }
            let dataURL = try Self.pngDataURL(for: image)
            let title = window.title.isEmpty ? "(untitled)" : window.title
            let message = "Captured window \(window.windowID) from \(window.ownerName): \(title)"
            return AssistantToolExecutionResult(
                contentItems: [
                    .init(type: "inputText", text: message, imageURL: nil),
                    .init(type: "inputImage", text: nil, imageURL: dataURL)
                ],
                success: true,
                summary: message
            )
        } catch {
            let message = error.localizedDescription
            return AssistantToolExecutionResult(
                contentItems: [.init(type: "inputText", text: message, imageURL: nil)],
                success: false,
                summary: message
            )
        }
    }

    static func resolveWindow(request: WindowCaptureRequest) -> WindowInfo? {
        resolveWindow(
            windowID: request.windowID,
            appName: request.appName,
            title: request.title,
            preferFrontmost: false
        )
    }

    static func resolveWindow(
        windowID: Int? = nil,
        appName: String? = nil,
        title: String? = nil,
        preferFrontmost: Bool,
        preferredOwnerPID: pid_t? = nil
    ) -> WindowInfo? {
        let windows = visibleWindows()
        if let windowID {
            return windows.first(where: { $0.windowID == windowID })
        }

        let loweredApp = appName?.lowercased()
        let loweredTitle = title?.lowercased()
        let frontmostPID = preferredOwnerPID ?? NSWorkspace.shared.frontmostApplication?.processIdentifier

        func matches(_ window: WindowInfo) -> Bool {
            if let loweredApp, !window.ownerName.lowercased().contains(loweredApp) {
                return false
            }
            if let loweredTitle, !window.title.lowercased().contains(loweredTitle) {
                return false
            }
            return true
        }

        if preferFrontmost, let frontmostPID {
            if let matchingFrontmost = windows.first(where: { $0.ownerPID == frontmostPID && matches($0) }) {
                return matchingFrontmost
            }
        }

        if let matching = windows.first(where: matches) {
            return matching
        }

        if preferFrontmost, let frontmostPID {
            return windows.first(where: { $0.ownerPID == frontmostPID })
        }

        return windows.first
    }

    static func visibleWindows() -> [WindowInfo] {
        let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return raw.compactMap { item in
            guard let windowID = integer(from: item[kCGWindowNumber as String]),
                  let ownerName = item[kCGWindowOwnerName as String] as? String,
                  let ownerPIDNumber = item[kCGWindowOwnerPID as String] as? NSNumber,
                  let boundsDictionary = item[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                  bounds.width >= 80,
                  bounds.height >= 40 else {
                return nil
            }
            let title = (item[kCGWindowName as String] as? String) ?? ""
            let layer = integer(from: item[kCGWindowLayer as String]) ?? 0
            let alpha = (item[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            return WindowInfo(
                windowID: windowID,
                ownerName: ownerName,
                ownerPID: pid_t(ownerPIDNumber.intValue),
                title: title,
                bounds: bounds,
                layer: layer,
                alpha: alpha,
                displayID: displayID(for: bounds)
            )
        }
        .filter { $0.layer == 0 && $0.alpha > 0.01 }
    }

    private static func normalizedDictionary(from arguments: Any) -> [String: Any]? {
        if let dictionary = arguments as? [String: Any] {
            return dictionary
        }
        if let json = arguments as? String,
           let data = json.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return parsed
        }
        return nil
    }

    private static func integer(from value: Any?) -> Int? {
        if let int = value as? Int {
            return int
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let text = value as? String {
            return Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func boolean(from value: Any?) -> Bool? {
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let text = value as? String {
            switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1":
                return true
            case "false", "no", "0":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    private static func activeScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    static func activeDisplayInfo() -> (displayID: CGDirectDisplayID, frame: CGRect)? {
        guard let screen = activeScreen(),
              let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return (CGDirectDisplayID(screenNumber.uint32Value), screen.frame)
    }

    static func captureDisplayImage(displayID: CGDirectDisplayID) -> CGImage? {
        CGDisplayCreateImage(displayID)
    }

    static func captureWindowImage(for window: WindowInfo) -> CGImage? {
        CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            CGWindowID(window.windowID),
            [.bestResolution]
        )
    }

    static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return screenNumber.uint32Value == displayID
        }
    }

    private static func displayID(for bounds: CGRect) -> CGDirectDisplayID? {
        let midpoint = CGPoint(x: bounds.midX, y: bounds.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(midpoint) }) ?? NSScreen.main,
              let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(screenNumber.uint32Value)
    }

    private static func dataURL(for image: NSImage) throws -> String? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw AssistantWindowAutomationServiceError.invalidImagePath
        }
        return "data:image/png;base64,\(pngData.base64EncodedString())"
    }

    private static func pngDataURL(for image: CGImage) throws -> String {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            throw AssistantWindowAutomationServiceError.captureFailed
        }
        return "data:image/png;base64,\(pngData.base64EncodedString())"
    }
}
