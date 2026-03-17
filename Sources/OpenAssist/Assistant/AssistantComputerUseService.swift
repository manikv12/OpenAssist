import AppKit
import Carbon
import CoreGraphics
import Foundation

enum AssistantComputerUseToolDefinition {
    static let name = "computer_use"
    static let toolKind = "computerUse"

    static let description = """
    Use the local computer for browser or GUI work on the current screen. Best for tasks that need clicking, typing, scrolling, or reading what is visible. This works best when the needed browser or app is already frontmost.
    """

    static let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "task": [
                "type": "string",
                "description": "What to do on the computer."
            ],
            "app": [
                "type": "string",
                "description": "Optional app or site hint, for example 'Brave browser' or 'System Settings'."
            ],
            "reason": [
                "type": "string",
                "description": "Short reason why computer control is needed."
            ]
        ],
        "required": ["task"],
        "additionalProperties": true
    ]

    static func dynamicToolSpec() -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": inputSchema
        ]
    }
}

actor AssistantComputerUseService {
    struct ToolExecutionResult: Sendable {
        struct ContentItem: Sendable {
            let type: String
            let text: String?
            let imageURL: String?

            func dictionaryRepresentation() -> [String: Any] {
                var dictionary: [String: Any] = ["type": type]
                if let text {
                    dictionary["text"] = text
                }
                if let imageURL {
                    dictionary["imageUrl"] = imageURL
                }
                return dictionary
            }
        }

        let contentItems: [ContentItem]
        let success: Bool
        let summary: String
    }

    struct ParsedTask: Equatable, Sendable {
        let task: String
        let appHint: String?
        let reason: String?

        var prompt: String {
            var sections: [String] = [task]
            if let appHint, !appHint.isEmpty {
                sections.append("Use this app/site if helpful: \(appHint)")
            }
            if let reason, !reason.isEmpty {
                sections.append("Reason: \(reason)")
            }
            return sections.joined(separator: "\n")
        }
    }

    private enum ServiceError: LocalizedError {
        case missingAuthentication
        case accessibilityRequired
        case screenRecordingRequired
        case invalidArguments
        case unsupportedSafetyCheck(String)
        case requestFailed(String)
        case invalidResponse
        case stepLimitReached
        case screenshotFailed

        var errorDescription: String? {
            switch self {
            case .missingAuthentication:
                return "Computer Use needs an OpenAI connection. Connect OpenAI in AI Studio or add an OpenAI API key first."
            case .accessibilityRequired:
                return "Computer Use needs macOS Accessibility permission so Open Assist can click and type."
            case .screenRecordingRequired:
                return "Computer Use needs macOS Screen Recording permission so Open Assist can see the current screen."
            case .invalidArguments:
                return "Computer Use was called without a usable task."
            case .unsupportedSafetyCheck(let message):
                return message
            case .requestFailed(let message):
                return message
            case .invalidResponse:
                return "OpenAI returned an unexpected Computer Use response."
            case .stepLimitReached:
                return "Computer Use stopped after too many steps."
            case .screenshotFailed:
                return "Computer Use could not capture the current screen."
            }
        }
    }

    private enum Credential {
        case apiKey(String)
        case oauth(PromptRewriteOAuthSession)
    }

    private struct AuthContext {
        let credential: Credential
        let endpoint: URL
        let modelID: String
    }

    private struct ResponseEnvelope {
        let id: String?
        let raw: [String: Any]
    }

    private struct ComputerCall {
        let callID: String
        let actions: [[String: Any]]
        let pendingSafetyChecks: [[String: Any]]
    }

    private typealias DisplaySnapshot = LocalAutomationDisplaySnapshot

    private static let maxSteps = 24
    private static let defaultModelID = "gpt-5.4"

    private let session: URLSession
    private let helper: LocalAutomationHelper

    init(
        session: URLSession = .shared,
        helper: LocalAutomationHelper = .shared
    ) {
        self.session = session
        self.helper = helper
    }

    func run(arguments: Any, preferredModelID: String?) async -> ToolExecutionResult {
        var lastScreenshot: DisplaySnapshot?

        do {
            let parsedTask = try Self.parseTask(from: arguments)
            let auth = try await resolveAuth(preferredModelID: preferredModelID)

            var response = try await createInitialResponse(
                prompt: parsedTask.prompt,
                auth: auth
            )

            for _ in 0..<Self.maxSteps {
                if let computerCall = Self.extractComputerCall(from: response.raw) {
                    if !computerCall.pendingSafetyChecks.isEmpty {
                        let joined = computerCall.pendingSafetyChecks.compactMap { check -> String? in
                            let message = (check["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                            let code = (check["code"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                            if let message, !message.isEmpty {
                                return message
                            }
                            if let code, !code.isEmpty {
                                return code
                            }
                            return nil
                        }
                        .joined(separator: "\n")

                        throw ServiceError.unsupportedSafetyCheck(
                            joined.isEmpty
                                ? "Computer Use paused because OpenAI returned a safety check that this version of Open Assist cannot confirm yet."
                                : "Computer Use paused because OpenAI returned a safety check:\n\(joined)"
                        )
                    }

                    lastScreenshot = try await execute(
                        actions: computerCall.actions,
                        previousSnapshot: lastScreenshot
                    )
                    response = try await continueResponse(
                        previousResponseID: response.id,
                        callID: computerCall.callID,
                        screenshot: lastScreenshot,
                        auth: auth
                    )
                    continue
                }

                let finalText = Self.extractOutputText(from: response.raw)
                let summary = finalText?.nonEmpty ?? "Computer Use finished."
                var items: [ToolExecutionResult.ContentItem] = [
                    .init(type: "inputText", text: summary, imageURL: nil)
                ]
                if let lastScreenshot {
                    items.append(.init(type: "inputImage", text: nil, imageURL: lastScreenshot.imageDataURL))
                }
                return ToolExecutionResult(contentItems: items, success: true, summary: summary)
            }

            throw ServiceError.stepLimitReached
        } catch {
            let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = message.isEmpty ? "Computer Use failed." : message
            var items: [ToolExecutionResult.ContentItem] = [
                .init(type: "inputText", text: summary, imageURL: nil)
            ]
            if let lastScreenshot {
                items.append(.init(type: "inputImage", text: nil, imageURL: lastScreenshot.imageDataURL))
            }
            return ToolExecutionResult(
                contentItems: items,
                success: false,
                summary: summary
            )
        }
    }

    static func parseTask(from arguments: Any) throws -> ParsedTask {
        if let text = (arguments as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return ParsedTask(task: text, appHint: nil, reason: nil)
        }

        guard let dictionary = arguments as? [String: Any] else {
            throw ServiceError.invalidArguments
        }

        let task = [
            dictionary["task"] as? String,
            dictionary["goal"] as? String,
            dictionary["instruction"] as? String,
            dictionary["prompt"] as? String
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first(where: { !$0.isEmpty })

        guard let task else {
            throw ServiceError.invalidArguments
        }

        let appHint = [
            dictionary["app"] as? String,
            dictionary["application"] as? String,
            dictionary["site"] as? String
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first(where: { !$0.isEmpty })

        let reason = [
            dictionary["reason"] as? String,
            dictionary["why"] as? String,
            dictionary["context"] as? String
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first(where: { !$0.isEmpty })

        return ParsedTask(task: task, appHint: appHint, reason: reason)
    }

    static func toolPayload(for callID: String, screenshotDataURL: String) -> [[String: Any]] {
        [[
            "type": "computer_call_output",
            "call_id": callID,
            "output": [
                "type": "computer_screenshot",
                "image_url": screenshotDataURL
            ]
        ]]
    }

    static func extractOutputText(from raw: [String: Any]) -> String? {
        if let outputText = raw["output_text"] as? String,
           let trimmed = outputText.nonEmpty {
            return trimmed
        }

        if let output = raw["output"] as? [[String: Any]] {
            var textParts: [String] = []
            for item in output {
                if let content = item["content"] as? [[String: Any]] {
                    for part in content {
                        if let text = (part["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !text.isEmpty {
                            textParts.append(text)
                        }
                    }
                }
                if let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty {
                    textParts.append(text)
                }
            }

            let merged = textParts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return merged.nonEmpty
        }

        return nil
    }

    static func responsesEndpointStringForTesting(from baseURL: String) -> String? {
        responsesEndpoint(from: baseURL)?.absoluteString
    }

    private func resolveAuth(preferredModelID: String?) async throws -> AuthContext {
        let snapshot = await MainActor.run { () -> (apiKey: String, baseURL: String, oauth: PromptRewriteOAuthSession?) in
            let settings = SettingsStore.shared
            return (
                settings.promptRewriteOpenAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines),
                settings.promptRewriteOpenAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                PromptRewriteOAuthCredentialStore.loadSession(for: .openAI)
            )
        }

        let explicitModel = ProcessInfo.processInfo.environment["OPENASSIST_COMPUTER_USE_MODEL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let modelID = explicitModel?.nonEmpty
            ?? preferredModelID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? Self.defaultModelID

        if !snapshot.apiKey.isEmpty {
            guard let endpoint = Self.responsesEndpoint(from: snapshot.baseURL) else {
                throw ServiceError.requestFailed(
                    "Computer Use could not build the OpenAI endpoint from the configured base URL."
                )
            }
            return AuthContext(
                credential: .apiKey(snapshot.apiKey),
                endpoint: endpoint,
                modelID: modelID
            )
        }

        if let oauth = snapshot.oauth {
            let refreshed = try await PromptRewriteProviderOAuthService.shared.refreshSessionIfNeeded(
                oauth,
                providerMode: .openAI
            )
            guard let endpoint = URL(string: "https://chatgpt.com/backend-api/codex/responses") else {
                throw ServiceError.requestFailed("Computer Use could not build the OpenAI OAuth endpoint.")
            }
            return AuthContext(
                credential: .oauth(refreshed),
                endpoint: endpoint,
                modelID: modelID
            )
        }

        throw ServiceError.missingAuthentication
    }

    private func createInitialResponse(prompt: String, auth: AuthContext) async throws -> ResponseEnvelope {
        try await sendResponseRequest(
            payload: [
                "model": auth.modelID,
                "tools": [["type": "computer"]],
                "input": prompt
            ],
            auth: auth
        )
    }

    private func continueResponse(
        previousResponseID: String?,
        callID: String,
        screenshot: DisplaySnapshot?,
        auth: AuthContext
    ) async throws -> ResponseEnvelope {
        guard let previousResponseID = previousResponseID?.nonEmpty,
              let screenshot else {
            throw ServiceError.invalidResponse
        }

        return try await sendResponseRequest(
            payload: [
                "model": auth.modelID,
                "tools": [["type": "computer"]],
                "previous_response_id": previousResponseID,
                "input": Self.toolPayload(for: callID, screenshotDataURL: screenshot.imageDataURL)
            ],
            auth: auth
        )
    }

    private func sendResponseRequest(
        payload: [String: Any],
        auth: AuthContext
    ) async throws -> ResponseEnvelope {
        guard JSONSerialization.isValidJSONObject(payload) else {
            throw ServiceError.requestFailed("Computer Use could not encode the OpenAI request.")
        }

        var request = URLRequest(url: auth.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        switch auth.credential {
        case .apiKey(let apiKey):
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .oauth(let session):
            request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
            if let accountID = session.accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
               !accountID.isEmpty {
                request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
            }
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.requestFailed("Computer Use received an invalid OpenAI response.")
        }

        guard (200...299).contains(http.statusCode) else {
            let detail = Self.errorDetail(from: data)
            throw ServiceError.requestFailed(
                detail.isEmpty
                    ? "Computer Use request failed with status \(http.statusCode)."
                    : detail
            )
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServiceError.invalidResponse
        }

        return ResponseEnvelope(id: json["id"] as? String, raw: json)
    }

    private func execute(
        actions: [[String: Any]],
        previousSnapshot: DisplaySnapshot?
    ) async throws -> DisplaySnapshot {
        do {
            return try await helper.executeComputerActions(
                actions,
                previousSnapshot: previousSnapshot
            )
        } catch let error as LocalAutomationError {
            switch error {
            case .accessibilityRequired:
                throw ServiceError.accessibilityRequired
            case .screenRecordingRequired:
                throw ServiceError.screenRecordingRequired
            case .screenshotFailed:
                throw ServiceError.screenshotFailed
            default:
                throw ServiceError.requestFailed(error.localizedDescription)
            }
        }
    }

    private func captureSnapshot() throws -> DisplaySnapshot {
        guard let screen = Self.activeScreen() else {
            throw ServiceError.screenshotFailed
        }
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw ServiceError.screenshotFailed
        }

        let displayID = CGDirectDisplayID(screenNumber.uint32Value)
        guard let image = CGDisplayCreateImage(displayID) else {
            throw ServiceError.screenshotFailed
        }

        let imageSize = CGSize(width: image.width, height: image.height)
        let imageDataURL = try Self.pngDataURL(for: image)
        return DisplaySnapshot(
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

    private func screenPoint(from action: [String: Any], snapshot: DisplaySnapshot) throws -> CGPoint {
        let x = number(from: action["x"])
        let y = number(from: action["y"])
        guard let x, let y else {
            throw ServiceError.invalidArguments
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

    private func dragPath(from action: [String: Any], snapshot: DisplaySnapshot) throws -> [CGPoint] {
        guard let path = action["path"] as? [[String: Any]], !path.isEmpty else {
            throw ServiceError.invalidArguments
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
            throw ServiceError.requestFailed("Computer Use could not create a scroll event.")
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
            if let keyCode = Self.keyCode(for: key) {
                guard
                    let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
                    let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
                else {
                    throw ServiceError.requestFailed("Computer Use could not create a key event.")
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
                    throw ServiceError.requestFailed("Computer Use could not create a return key event.")
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
                throw ServiceError.requestFailed("Computer Use could not create a typing event.")
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
            throw ServiceError.requestFailed("Computer Use could not access the macOS event source.")
        }
        return source
    }

    private static func keyCode(for key: String) -> CGKeyCode? {
        keyCodeMap[key]
    }

    private func pause(for seconds: TimeInterval) async throws {
        let nanoseconds = UInt64((seconds * 1_000_000_000).rounded())
        try await Task.sleep(nanoseconds: nanoseconds)
    }

    private static func responsesEndpoint(from baseURL: String) -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.isEmpty ? "https://api.openai.com/v1" : trimmed
        let withoutTrailingSlash = normalized.hasSuffix("/") ? String(normalized.dropLast()) : normalized

        let endpointString = withoutTrailingSlash.hasSuffix("/responses")
            ? withoutTrailingSlash
            : withoutTrailingSlash + "/responses"
        guard let url = URL(string: endpointString),
              let scheme = url.scheme?.lowercased(),
              (scheme == "https" || scheme == "http"),
              let host = url.host,
              !host.isEmpty else {
            return nil
        }
        return url
    }

    private static func errorDetail(from data: Data) -> String {
        guard !data.isEmpty else { return "" }
        if let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let error = json["error"] as? [String: Any] {
                let message = (error["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let message, !message.isEmpty {
                    return message
                }
            }
            let message = (json["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let message, !message.isEmpty {
                return message
            }
        }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func pngDataURL(for image: CGImage) throws -> String {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            throw ServiceError.screenshotFailed
        }
        return "data:image/png;base64,\(pngData.base64EncodedString())"
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

    private static func extractComputerCall(from raw: [String: Any]) -> ComputerCall? {
        guard let output = raw["output"] as? [[String: Any]] else { return nil }

        for item in output {
            guard (item["type"] as? String) == "computer_call" else { continue }
            let callID = (item["call_id"] as? String)?.nonEmpty ?? (item["id"] as? String)?.nonEmpty
            guard let callID else { continue }

            let pendingSafetyChecks = item["pending_safety_checks"] as? [[String: Any]] ?? []
            if let actions = item["actions"] as? [[String: Any]], !actions.isEmpty {
                return ComputerCall(callID: callID, actions: actions, pendingSafetyChecks: pendingSafetyChecks)
            }
            if let action = item["action"] as? [String: Any] {
                return ComputerCall(callID: callID, actions: [action], pendingSafetyChecks: pendingSafetyChecks)
            }
            return ComputerCall(callID: callID, actions: [["type": "screenshot"]], pendingSafetyChecks: pendingSafetyChecks)
        }

        return nil
    }

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
}
